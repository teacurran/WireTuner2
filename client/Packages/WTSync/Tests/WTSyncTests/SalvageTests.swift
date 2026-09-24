import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// SYNC-010: salvage of a retired replica's unsent changes -- rebased onto fresh ids against the
/// current state, with ops naming collected tombstones dropped and listed.
@Suite struct SalvageTests {
    let scratch = Scratch()

    /// A layer of replica 9 at counter `counter`, sequenced at `serverSeq`.
    static func remoteLayer(_ name: String, counter: UInt64, seq: UInt64 = 1) -> Wiretuner_Doc_V1_Change {
        var change = Fixture.change(9, seq: seq, start: counter, [Fixture.createLayer(name)])
        change.wallTimeMs = 0
        return change
    }

    @discardableResult
    func perform(_ store: LocalStore, _ label: String, _ ops: [Wiretuner_Doc_V1_Op]) async throws -> OpID {
        let change = try await store.perform(OpsCommand(label, ops: ops), recording: Fixture.recording()).change!
        return OpID(counter: change.startCounter, replica: change.replica)
    }

    /// Every id a change's ops carry, as `replica` values in their JSON.
    static func replicas(in changes: [Wiretuner_Doc_V1_Change]) throws -> Set<String> {
        var found: Set<String> = []
        for op in changes.flatMap(\.ops) {
            let text = try op.jsonString()
            var rest = Substring(text)
            while let range = rest.range(of: "\"replica\":\"") {
                rest = rest[range.upperBound...]
                found.insert(String(rest.prefix { $0 != "\"" }))
            }
        }
        return found
    }

    @Test func unsentChangesAreReissuedOnFreshIdsWithTheirReferences() async throws {
        let store = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        let remote = Self.remoteLayer("R", counter: 1)
        _ = try await store.receive(remote, serverSeq: 1)
        let r = OpID(counter: 1, replica: 9)
        // A day's work: a layer, a child under it, renames, a text block typed and edited.
        let a = try await perform(store, "Create", [Fixture.createLayer("A", position: [0x81])])
        try await perform(store, "Child", [Ops.create(parent: a, position: [0x80], props: Fixture.layer(name: "child")),
                                            Fixture.rename(a, "A2")])
        try await perform(store, "Rename R", [Fixture.rename(r, "R2")])
        let block = try await perform(store, "Text", [Ops.create(parent: Fixture.layers, position: [0x82], props: Fixture.textBlock())])
        let typed = try await perform(store, "Type", [Ops.textInsert(block, Fixture.text, "hello")])
        try await perform(store, "Type more", [Ops.textInsert(block, Fixture.text, " world",
                                                              left: OpID(counter: typed.counter + 4, replica: typed.replica))])
        // One delete spanning both typed runs ("lo w"): split at the change boundary.
        try await perform(store, "Delete", [Ops.textDelete(block, Fixture.text, first: OpID(counter: typed.counter + 3, replica: typed.replica),
                                                            count: 4)])
        let expected = await store.read { state in state.text(block, Fixture.text)?.string }
        #expect(expected == "helorld")
        #expect(try await store.hasUnsentChanges())

        // Expiry: salvage begins, the store empties, the server's state comes back.
        #expect(try await store.beginSalvage(reason: .expired) == 43)
        #expect(try await store.pendingSalvageCount() == 7)
        #expect(try await !store.hasUnsentChanges())
        #expect(await store.lastServerSeq == 0)
        #expect(await store.read { $0.store.nodes.isEmpty })
        #expect(await store.summary().undo.undoCount == 0)
        _ = try await store.receive(remote, serverSeq: 1)
        let report = try #require(try await store.applySalvage(recording: Fixture.recording()))
        #expect(report.reason == .expired && report.salvagedChanges == 7 && report.recoveredChanges == 7 && report.dropped.isEmpty)
        #expect(report.reissuedOps == 8 && report.needsReview)
        #expect(try await store.pendingSalvageCount() == 0)
        #expect(try await store.applySalvage(recording: Fixture.recording()) == nil)

        let outbox = try await store.outbox()
        #expect(outbox.map(\.seq) == Array(1...7) && outbox.allSatisfy { $0.replica == 43 })
        #expect(outbox.map(\.label) == ["Create", "Child", "Rename R", "Text", "Type", "Type more", "Delete"])
        #expect(try Self.replicas(in: outbox) == ["43", "9"])   // no id of the retired replica is left
        let newA = OpID(counter: outbox[0].startCounter, replica: 43)
        let newBlock = OpID(counter: outbox[3].startCounter, replica: 43)
        await store.read { state in
            #expect(state.register(newA, Fixture.name)?.value == Fixture.nameValue("A2"))
            #expect(state.register(r, Fixture.name)?.value == Fixture.nameValue("R2"))
            #expect(state.store.children(newA).count == 1)
            #expect(state.text(newBlock, Fixture.text)?.string == "helorld")
            #expect(!state.store.exists(a))
        }
        #expect(outbox[6].ops[0].textDelete.ranges.map(\.count) == [2, 2])
    }

    /// The server's state after garbage collection: `deleted` nodes compacted, deleted characters gone.
    static func collected(_ changes: [Wiretuner_Doc_V1_Change]) -> EngineState {
        var state = EngineState()
        for (index, change) in changes.enumerated() {
            state.apply(change, serverSeq: UInt64(index + 1))
        }
        state.collect(stableSeq: UInt64(changes.count), now: EngineState.deletedNodeRetentionMs + 1)
        return state
    }

    @Test func salvageAfterPruningDropsOnlyOpsNamingCollectedTombstones() async throws {
        let store = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        let t = OpID(counter: 1, replica: 9)
        let block = OpID(counter: 2, replica: 9)
        let base = [Self.remoteLayer("T", counter: 1),
                    Fixture.change(9, seq: 2, start: 2, [Ops.create(parent: Fixture.layers, position: [0x90], props: Fixture.textBlock())]),
                    Fixture.change(9, seq: 3, start: 3, [Ops.textInsert(block, Fixture.text, "abc")])]
        for (index, change) in base.enumerated() {
            _ = try await store.receive(change, serverSeq: UInt64(index + 1))
        }
        let c = OpID(counter: 5, replica: 9)
        // Offline: edits of T, of the text after "c", and of a new layer.
        try await perform(store, "Rename T", [Fixture.rename(t, "T2")])
        let child = try await perform(store, "Child of T", [Ops.create(parent: t, position: [0x80], props: Fixture.layer(name: "c"))])
        try await perform(store, "Rename child", [Fixture.rename(child, "c2")])
        try await perform(store, "Type", [Ops.textInsert(block, Fixture.text, "x", left: c)])
        let kept = try await perform(store, "New", [Fixture.createLayer("N", position: [0x70]), Fixture.rename(t, "T3")])
        // Meanwhile T was deleted and "c" too, and the server collected both.
        let deletions = [Fixture.change(9, seq: 4, start: 10, [Ops.setDeleted(t)]),
                         Fixture.change(9, seq: 5, start: 11, [Ops.textDelete(block, Fixture.text, first: c, count: 1)])]
        let server = Self.collected(base + deletions)
        #expect(!server.store.exists(t) && server.text(block, Fixture.text)?.contains(c) == false)

        try await store.beginSalvage(reason: .expired)
        try await store.installSnapshot(server, serverSeq: 5)
        let report = try #require(try await store.applySalvage(recording: Fixture.recording()))
        #expect(report.salvagedChanges == 5 && report.recoveredChanges == 1 && report.reissuedOps == 1)
        #expect(report.dropped.map(\.label) == ["Rename T", "Child of T", "Rename child", "Type", "New"])
        #expect(report.dropped.map(\.op) == ["SetFields", "CreateNode", "SetFields", "TextInsert", "SetFields"])
        #expect(report.dropped.map(\.missing) == [t, t, child, c, t])
        #expect(report.dropped.last?.opIndex == 1 && report.dropped[0].seq == 1 && report.dropped[0].replica == 42)
        // The surviving change keeps its counter layout: the dropped op is a Noop.
        let outbox = try await store.outbox()
        #expect(outbox.count == 1 && outbox[0].ops.count == 2 && outbox[0].ops[1] == Ops.noop())
        let fresh = OpID(counter: outbox[0].startCounter, replica: 43)
        #expect(await store.read { $0.register(fresh, Fixture.name)?.value } == Fixture.nameValue("N"))
        #expect(kept.replica == 42)
    }

    @Test func discardingLocalChangesEmptiesTheStore() async throws {
        let store = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        try await perform(store, "Create", [Fixture.createLayer("A")])
        #expect(try await store.discardLocalChanges() == 43)
        #expect(try await store.outbox().isEmpty)
        #expect(try await store.pendingSalvageCount() == 0)
        #expect(await store.read { $0.store.nodes.isEmpty })
        try await store.close()
        let reopened = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        #expect(await reopened.replica == 43)
        #expect(await reopened.lastServerSeq == 0)
    }

    @Test func reviewHoldsAndTheSyncTimeSurviveReopening() async throws {
        let store = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        #expect(try await store.reviewHold() == nil)
        #expect(try await store.lastSyncedAt() == nil)
        let report = SalvageReport(reason: .conflict, dropped: [
            SalvageReport.Dropped(replica: 1, seq: 2, label: "L", opIndex: 0, op: "SetFields", missingCounter: 5, missingReplica: 9)])
        #expect(report.needsReview)
        try await store.setReviewHold(LocalStore.ReviewHold(kind: .recovered, baseSeq: 3, report: report))
        try await store.markSynced(at: Date(timeIntervalSince1970: 1_000))
        try await store.close()
        let reopened = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        #expect(try await reopened.reviewHold() == LocalStore.ReviewHold(kind: .recovered, baseSeq: 3, report: report))
        #expect(try await reopened.lastSyncedAt() == Date(timeIntervalSince1970: 1_000))
        try await reopened.setReviewHold(LocalStore.ReviewHold(kind: .merge, baseSeq: 7))
        #expect(try await reopened.reviewHold() == LocalStore.ReviewHold(kind: .merge, baseSeq: 7))
        try await reopened.setReviewHold(nil)
        #expect(try await reopened.reviewHold() == nil)
        try await reopened.close()
        await #expect(throws: LocalStore.Failure.closed) { try await reopened.reviewHold() }
        await #expect(throws: LocalStore.Failure.closed) { try await reopened.lastSyncedAt() }
        await #expect(throws: LocalStore.Failure.closed) { try await reopened.hasUnsentChanges() }
        await #expect(throws: LocalStore.Failure.closed) { try await reopened.pendingSalvageCount() }
        await #expect(throws: LocalStore.Failure.closed) { try await reopened.applySalvage(recording: Fixture.recording()) }
    }

    // MARK: The rebase itself

    @Test func idsOutsideSalvagedChangesAreKeptAndValuesSurviveTheRewrite() {
        var rebase = SalvageRebase(replica: 50, reason: .conflict)
        let state = EngineState()
        #expect(rebase.remap(Fixture.moveTo(.wellKnown(4), 0.1 + 0.2)) == Fixture.moveTo(.wellKnown(4), 0.1 + 0.2))
        let change = Fixture.change(42, seq: 1, start: 10, [Fixture.createLayer("A"), Ops.noop()])
        let ops = rebase.rebase(change, startCounter: 100, state: state).ops
        #expect(ops?.count == 2 && ops?[1] == Ops.noop())
        #expect(rebase.map(OpID(counter: 10, replica: 42)) == OpID(counter: 100, replica: 50))
        #expect(rebase.map(OpID(counter: 12, replica: 42)) == OpID(counter: 12, replica: 42))
        #expect(rebase.map(OpID(counter: 10, replica: 7)) == OpID(counter: 10, replica: 7))
        // Doubles, bytes and strings come back as they were.
        var props = Fixture.layer(name: "émoji 🎨", tx: 1e-300)
        props.layer.common.transform.ty = -0.1
        let op = Ops.set(OpID(counter: 10, replica: 42), [Fixture.transform, Fixture.name], values: props)
        let remapped = rebase.remap(op)
        #expect(remapped.set.values == props && OpID(remapped.set.node) == OpID(counter: 100, replica: 50))
        #expect(SalvageRebase.integer(NSNumber(value: 5)) == 5 && SalvageRebase.integer("7") == 7 && SalvageRebase.integer(true) == 1)
    }

    /// TEST-001 finding (b): a salvaged change over the limits is re-issued as consecutive changes
    /// within them, each mapping its own ids.
    @Test func aChangeOverTheLimitsIsReissuedInPieces() {
        var rebase = SalvageRebase(replica: 50, reason: .oversized, limits: ChangeLimits(ops: 2))
        var state = EngineState()
        let a = OpID(counter: 10, replica: 42)
        let b = OpID(counter: 12, replica: 42)
        let change = Fixture.change(42, seq: 1, start: 10, [Fixture.createLayer("A"), Fixture.rename(a, "a"), Fixture.createLayer("B"),
                                                            Fixture.rename(b, "b"), Fixture.createLayer("C")], label: "Paste")
        let first = rebase.rebase(change, startCounter: 100, state: state)
        #expect(first.next == 2 && first.ops == [Fixture.createLayer("A"), Fixture.rename(OpID(counter: 100, replica: 50), "a")])
        state.apply(Fixture.change(50, seq: 1, start: 100, first.ops!))
        let second = rebase.rebase(change, from: 2, startCounter: 200, state: state)
        #expect(second.next == 4 && second.ops == [Fixture.createLayer("B"), Fixture.rename(OpID(counter: 200, replica: 50), "b")])
        state.apply(Fixture.change(50, seq: 2, start: 200, second.ops!))
        let third = rebase.rebase(change, from: 4, startCounter: 300, state: state)
        #expect(third.next == 5 && third.ops == [Fixture.createLayer("C")])
        #expect(rebase.map(a) == OpID(counter: 100, replica: 50) && rebase.map(OpID(counter: 11, replica: 42)) == OpID(counter: 101, replica: 50))
        #expect(rebase.map(b) == OpID(counter: 200, replica: 50) && rebase.map(OpID(counter: 14, replica: 42)) == OpID(counter: 300, replica: 50))
        #expect(rebase.report == SalvageReport(reason: .oversized, salvagedChanges: 1, recoveredChanges: 1, reissuedOps: 5))
        #expect(!rebase.report.needsReview)
        // By bytes: two layers do not fit, so each goes alone.
        let size = ChangeLimits.headerSize(change) + ChangeLimits.size(of: Fixture.createLayer("A")) + 1
        var bytes = SalvageRebase(replica: 50, reason: .oversized, limits: ChangeLimits(bytes: size))
        #expect(bytes.rebase(change, startCounter: 100, state: EngineState()).next == 1)
    }

    @Test func droppedOpsEndAPieceWhenTheirNoopsWouldNotFit() {
        var rebase = SalvageRebase(replica: 50, reason: .oversized, limits: ChangeLimits(ops: 4))
        let state = EngineState()
        let gone = OpID(counter: 99, replica: 8)
        // Counters: rename 10, X 11, "abc" 12...14, Y 15, "defgh" 16...20, Z 21.
        let change = Fixture.change(42, seq: 1, start: 10, [
            Fixture.rename(gone, "x"), Fixture.createLayer("X"), Ops.textInsert(gone, Fixture.text, "abc"), Fixture.createLayer("Y"),
            Ops.textInsert(gone, Fixture.text, "defgh"), Fixture.createLayer("Z"),
        ])
        // A drop before anything is issued is skipped; one whose Noops fit keeps its counters.
        let first = rebase.rebase(change, startCounter: 100, state: state)
        #expect(first.next == 3 && first.ops == [Fixture.createLayer("X"), Ops.noop(), Ops.noop(), Ops.noop()])
        // Five Noops do not fit after Y: the piece ends, and the next one skips the drop.
        let second = rebase.rebase(change, from: 3, startCounter: 200, state: state)
        #expect(second.next == 4 && second.ops == [Fixture.createLayer("Y")])
        let third = rebase.rebase(change, from: 4, startCounter: 300, state: state)
        #expect(third.next == 6 && third.ops == [Fixture.createLayer("Z")])
        #expect(rebase.report.dropped.map(\.opIndex) == [0, 2, 4] && rebase.report.reissuedOps == 3)
        #expect(rebase.map(OpID(counter: 11, replica: 42)) == OpID(counter: 100, replica: 50))
        #expect(rebase.map(OpID(counter: 15, replica: 42)) == OpID(counter: 200, replica: 50))
        #expect(rebase.map(OpID(counter: 21, replica: 42)) == OpID(counter: 300, replica: 50))
        #expect(rebase.map(OpID(counter: 16, replica: 42)) == OpID(counter: 16, replica: 42))
        #expect(rebase.map(OpID(counter: 10, replica: 42)) == OpID(counter: 10, replica: 42))
        // A piece of Noops only is not issued, and maps nothing.
        let noops = rebase.rebase(Fixture.change(42, seq: 2, start: 30, [Ops.noop(), Ops.noop()]), startCounter: 400, state: state)
        #expect(noops.ops == nil && noops.next == 2 && rebase.map(OpID(counter: 30, replica: 42)) == OpID(counter: 30, replica: 42))
    }

    @Test func theStoreReissuesAnOversizedChangeAsSeveral() async throws {
        let store = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        try await perform(store, "Paste", (0..<5).map { Fixture.createLayer("P\($0)", position: [0x80, UInt8($0)]) })
        try await store.beginSalvage(reason: .oversized)
        let empty = await store.read { $0.store.nodes.count }
        let report = try #require(try await store.applySalvage(recording: Fixture.recording(), limits: ChangeLimits(ops: 2)))
        let outbox = try await store.outbox()
        #expect(outbox.map(\.ops.count) == [2, 2, 1] && outbox.map(\.seq) == [1, 2, 3])
        #expect(outbox.allSatisfy { $0.label == "Paste" && $0.replica == 43 })
        #expect(report.reason == .oversized && report.recoveredChanges == 1 && report.reissuedOps == 5)
        #expect(await store.read { $0.store.nodes.count } == empty + 5)
    }

    @Test func textDeleteRangesSplitAtChangeBoundaries() {
        var rebase = SalvageRebase(replica: 50, reason: .conflict)
        var state = EngineState()
        state.apply(Fixture.change(9, seq: 1, start: 1, [Ops.create(parent: Fixture.layers, position: [0x80], props: Fixture.textBlock())]))
        let block = OpID(counter: 1, replica: 9)
        _ = rebase.rebase(Fixture.change(42, seq: 1, start: 10, [Ops.textInsert(block, Fixture.text, "abc")]), startCounter: 100, state: state)
        _ = rebase.rebase(Fixture.change(42, seq: 2, start: 20, [Ops.textInsert(block, Fixture.text, "def")]), startCounter: 200, state: state)
        // 10...12 and 20...22 are salvaged; 13...19 are not (another replica's clock moved past them).
        let op = rebase.remap(Ops.textDelete(block, Fixture.text, first: OpID(counter: 11, replica: 42), count: 12))
        #expect(op.textDelete.ranges.map { OpID($0.first) } == [OpID(counter: 101, replica: 50), OpID(counter: 13, replica: 42),
                                                                 OpID(counter: 200, replica: 50)])
        #expect(op.textDelete.ranges.map(\.count) == [2, 7, 3])
    }

    @Test func everyOpKindIsCheckedAgainstTheState() {
        var state = EngineState()
        state.apply(Fixture.change(9, seq: 1, start: 1, [Fixture.createLayer("A"),
                                                         Ops.create(parent: Fixture.layers, position: [0x81], props: Fixture.textBlock())]))
        let a = OpID(counter: 1, replica: 9)
        let block = OpID(counter: 2, replica: 9)
        state.apply(Fixture.change(9, seq: 2, start: 3, [Ops.textInsert(block, Fixture.text, "ab")]))
        let char = OpID(counter: 3, replica: 9)
        let sizes = RegisterPath([2, 5])
        var page = Wiretuner_Doc_V1_NodeProps()
        page.settings.customPageSizes = [Wiretuner_Doc_V1_CustomPageSize.with { $0.name = "A" }]
        state.apply(Fixture.change(9, seq: 3, start: 5, [Ops.elementInsert(.wellKnown(1), sizes, positions: [[0x80]], values: page)]))
        let element = sizes.element(OpID(counter: 5, replica: 9))
        let gone = OpID(counter: 99, replica: 8)
        let goneElement = sizes.element(gone)
        func check(_ op: Wiretuner_Doc_V1_Op) -> OpID? { SalvageRebase.missing(op, state: state, created: []) }
        func mark(_ start: OpID, _ end: OpID) -> Wiretuner_Doc_V1_Op {
            var mark = Wiretuner_Doc_V1_TextMark()
            mark.node = block.proto
            mark.text = Fixture.text.proto
            mark.start.char = Ops.elementID(start)
            mark.end.char = Ops.elementID(end)
            var op = Wiretuner_Doc_V1_Op()
            op.textMark = mark
            return op
        }
        let present: [Wiretuner_Doc_V1_Op] = [
            Fixture.createLayer("B"), Fixture.rename(a, "x"), Ops.move(a, parent: Fixture.layers, position: [0x70]), Ops.setDeleted(a),
            Ops.elementInsert(.wellKnown(1), sizes, positions: [[0x81]], values: page), Ops.elementMove(.wellKnown(1), element, position: [0x70]),
            Ops.elementDelete(.wellKnown(1), [element]), Ops.textInsert(block, Fixture.text, "c", left: char),
            Ops.textDelete(block, Fixture.text, first: char, count: 1), mark(char, .zero),
            Ops.setAdd(a, RegisterPath([150, 1, 30]), values: Wiretuner_Doc_V1_NodeProps()),
            Ops.setRemove(a, RegisterPath([150, 1, 30]), values: Wiretuner_Doc_V1_NodeProps()), Ops.noop(),
            Ops.set(block, [Fixture.text.element(char).child(6)], values: Wiretuner_Doc_V1_NodeProps()),
        ]
        #expect(present.map(check).allSatisfy { $0 == nil })
        let missing: [(Wiretuner_Doc_V1_Op, OpID)] = [
            (Ops.create(parent: gone, position: [0x80], props: Fixture.layer(name: "B")), gone), (Fixture.rename(gone, "x"), gone),
            (Ops.set(.wellKnown(1), [goneElement.child(2)], values: page), gone),
            (Ops.move(a, parent: gone, position: [0x70]), gone), (Ops.move(gone, parent: a, position: [0x70]), gone),
            (Ops.setDeleted(gone), gone), (Ops.elementInsert(gone, sizes, positions: [[0x81]], values: page), gone),
            (Ops.elementInsert(.wellKnown(1), goneElement.child(9), positions: [[0x81]], values: page), gone),
            (Ops.elementMove(.wellKnown(1), goneElement, position: [0x70]), gone), (Ops.elementDelete(.wellKnown(1), [goneElement]), gone),
            (Ops.textInsert(block, Fixture.text, "c", left: gone), gone), (Ops.textInsert(block, Fixture.text, "c", right: gone), gone),
            (Ops.textDelete(block, Fixture.text, first: gone, count: 1), gone), (mark(gone, char), gone), (mark(char, gone), gone),
            (Ops.setAdd(gone, RegisterPath([150, 1, 30]), values: page), gone),
            (Ops.setRemove(gone, RegisterPath([150, 1, 30]), values: page), gone),
            (Ops.textInsert(block, RegisterPath([130, 9]), "c", left: char), char),
        ]
        for (op, id) in missing {
            #expect(check(op) == id, "\(SalvageRebase.name(op))")
        }
        // An id an earlier op of the same change created is present.
        #expect(SalvageRebase.missing(Fixture.rename(gone, "x"), state: state, created: [gone]) == nil)
        #expect(SalvageRebase.missing(Ops.elementMove(.wellKnown(1), goneElement, position: [0x70]), state: state, created: [gone]) == nil)
        var unreadable = Wiretuner_Doc_V1_ElementMove()
        unreadable.node = OpID.wellKnown(1).proto
        var op = Wiretuner_Doc_V1_Op()
        op.elementMove = unreadable
        #expect(check(op) == nil)
        #expect(SalvageRebase.creates(Ops.textInsert(block, Fixture.text, "xyz"), id: OpID(counter: 7, replica: 1)).count == 3)
        #expect(SalvageRebase.creates(Fixture.rename(a, "x"), id: OpID(counter: 7, replica: 1)).isEmpty)
        #expect(SalvageRebase.name(Wiretuner_Doc_V1_Op()) == "Op")
        #expect((present + missing.map(\.0)).map(SalvageRebase.name).contains("ElementDelete"))
    }
}
