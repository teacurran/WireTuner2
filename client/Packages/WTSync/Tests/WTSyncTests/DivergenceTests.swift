import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// A reconnect as the measurement sees it: a shared base, unsent local changes of replica `me`,
/// and remote changes sequenced after the previous head, all applied to one state in Lamport order.
struct Divergent {
    static let me: UInt64 = 42
    static let priya: UInt64 = 7
    static let tom: UInt64 = 8

    var state = EngineState()
    var local: [Wiretuner_Doc_V1_Change] = []
    var remote: [Wiretuner_Doc_V1_Change] = []
    private var counter: UInt64 = 1
    private var serverSeq: UInt64 = 0
    private var seqs: [UInt64: UInt64] = [:]

    private mutating func change(_ replica: UInt64, _ ops: [Wiretuner_Doc_V1_Op]) -> (Wiretuner_Doc_V1_Change, OpID) {
        let seq = seqs[replica, default: 0] + 1
        seqs[replica] = seq
        let change = Fixture.change(replica, seq: seq, start: counter, ops)
        let first = OpID(counter: counter, replica: replica)
        counter += ops.reduce(0) { $0 + EngineState.counters($1) }
        return (change, first)
    }

    /// Changes both sides had before the gap (replica 9, sequenced before the previous head).
    @discardableResult
    mutating func base(_ ops: [Wiretuner_Doc_V1_Op]) -> OpID {
        let (change, first) = change(9, ops)
        serverSeq += 1
        state.apply(change, serverSeq: serverSeq)
        return first
    }

    @discardableResult
    mutating func mine(_ ops: [Wiretuner_Doc_V1_Op]) -> OpID {
        let (change, first) = change(Self.me, ops)
        _ = state.applyLocal(change)
        local.append(change)
        return first
    }

    @discardableResult
    mutating func theirs(_ ops: [Wiretuner_Doc_V1_Op], by replica: UInt64 = priya) -> OpID {
        let (change, first) = change(replica, ops)
        serverSeq += 1
        state.apply(change, serverSeq: serverSeq)
        remote.append(change)
        return first
    }

    /// `count` layers created on the base.
    mutating func layers(_ count: Int) -> [OpID] {
        (0..<count).map { base([Fixture.createLayer("L\($0)")]) }
    }

    func measure(gap: Duration = .zero, remoteComplete: Bool = true) -> Divergence {
        Divergence.measure(local: local, remote: remote, state: state, gap: gap, remoteComplete: remoteComplete)
    }
}

extension Fixture {
    static func note(_ node: OpID, _ note: String) -> Wiretuner_Doc_V1_Op {
        Ops.set(node, [Fixture.note], values: layer(note: note))
    }

    static func settings(_ path: [UInt32]) -> Wiretuner_Doc_V1_Op {
        Ops.set(.wellKnown(1), [RegisterPath(path)], values: Wiretuner_Doc_V1_NodeProps())
    }
}

@Suite struct DivergenceTests {
    /// A gap after offline work, past the brief-drop rule (D-070).
    static let apart: Duration = .seconds(3600)

    // MARK: Decision rules, one test per row of reconcile.adoc

    @Test func noOverlapUnderTheThresholdMergesSilently() {
        var world = Divergent()
        let nodes = world.layers(4)
        world.mine([Fixture.rename(nodes[0], "mine")])
        world.theirs([Fixture.rename(nodes[1], "hers")])
        world.theirs([Fixture.rename(nodes[2], "his")], by: Divergent.tom)
        world.theirs([Fixture.rename(nodes[3], "his again")], by: Divergent.tom)
        let divergence = world.measure()
        #expect(divergence.localOps == 1 && divergence.remoteOps == 3)
        #expect(divergence.localObjects == 1 && divergence.remoteObjects == 3 && divergence.overlapCount == 0)
        #expect(divergence.decision(.standard) == .silentMerge)
        let review = ReviewModel(divergence, decision: .silentMerge, names: [Divergent.priya: "Priya", Divergent.tom: "Tom"])
        #expect(review.mode == .readOnly && !review.holdsOutbox && review.documentActions.isEmpty)
        #expect(review.toast == "Merged 3 changes from Tom, Priya")
        #expect(review.summary == "You made 1 change offline. Meanwhile Tom made 2 and Priya made 1.")
        #expect(ReviewModel(divergence, decision: .silentMerge).toast == "Merged 3 changes from someone")
    }

    @Test func noOverlapButLargeOrLongOffersAReview() {
        var world = Divergent()
        let nodes = world.layers(2)
        world.mine([Fixture.rename(nodes[0], "a"), Fixture.note(nodes[0], "b")])
        world.theirs([Fixture.rename(nodes[1], "c")])
        let divergence = world.measure()
        #expect(divergence.decision(ReconcilePreferences(autoMergeBelow: 2)) == .suggestReview)
        #expect(world.measure(gap: .seconds(13 * 3600)).decision(.standard) == .suggestReview)
        #expect(world.measure(gap: .seconds(11 * 3600)).decision(.standard) == .silentMerge)
        #expect(world.measure(remoteComplete: false).decision(.standard) == .suggestReview)
        var review = ReviewModel(world.measure(gap: .seconds(14 * 3600)), decision: .suggestReview)
        #expect(review.summary == "You made 2 changes offline (14 h). Meanwhile someone made 1.")
        review.authors = []
        #expect(review.toast == "Merged 1 change")
    }

    @Test func aSmallOverlapIsListedObjectByObject() {
        var world = Divergent()
        let nodes = world.layers(10)
        for node in nodes {
            world.mine([Fixture.rename(node, "mine")])
        }
        world.theirs([Fixture.note(nodes[9], "theirs")])
        let others = world.layers(9)
        for node in others {
            world.theirs([Fixture.note(node, "new")])
        }
        let divergence = world.measure(gap: Self.apart)
        #expect(divergence.overlapCount == 1)
        #expect(divergence.decision(.standard) == .perObject)
        #expect(divergence.decision(ReconcilePreferences(alwaysAsk: true)) == .wholeDocument)
        let review = ReviewModel(divergence, decision: .perObject)
        #expect(review.mode == .perObject && review.holdsOutbox && review.overlapCount == 1)
        #expect(review.documentActions == [.keepMerged, .saveCopy, .keepBranch])
        #expect(review.entries[0].kind == .bothEdited && review.entries[0].actions == [.useMine, .useTheirs, .keepBoth])
        #expect(review.entries[0].id == "node:\(nodes[9])")
    }

    @Test func aLargeOverlapAsksForTheWholeDocument() {
        var world = Divergent()
        let nodes = world.layers(30)
        for node in nodes {
            world.mine([Fixture.rename(node, "mine")])
            world.theirs([Fixture.note(node, "theirs")])
        }
        let divergence = world.measure(gap: Self.apart)
        #expect(divergence.overlapCount == 30)
        #expect(divergence.decision(.standard) == .wholeDocument)
        #expect(ReviewModel(divergence, decision: .wholeDocument).mode == .wholeDocument)
        // Under the count, the share asks from five objects in common: five of eight is 62%.
        var shared = Divergent()
        let eight = shared.layers(8)
        for node in eight {
            shared.mine([Fixture.rename(node, "a")])
        }
        for node in eight.prefix(5) {
            shared.theirs([Fixture.note(node, "c")])
        }
        #expect(shared.measure(gap: Self.apart).decision(.standard) == .wholeDocument)
        #expect(shared.measure(gap: Self.apart).decision(ReconcilePreferences(askOverlapShare: 1)) == .perObject)
        #expect(shared.measure(gap: Self.apart).decision(ReconcilePreferences(shareMinimum: 6)) == .perObject)
        // D-070: one of two objects is 50%, but one object in common is listed on its own.
        var small = Divergent()
        let two = small.layers(2)
        small.mine([Fixture.rename(two[0], "a"), Fixture.rename(two[1], "b")])
        small.theirs([Fixture.note(two[0], "c")])
        #expect(small.measure(gap: Self.apart).decision(.standard) == .perObject)
        #expect(small.measure(gap: Self.apart).decision(ReconcilePreferences(shareMinimum: 1)) == .wholeDocument)
    }

    @Test func aLostLocalWriteToTheSameRegisterIsAlwaysListed() throws {
        var world = Divergent()
        let node = world.layers(1)[0]
        world.mine([Fixture.rename(node, "mine")])
        world.theirs([Fixture.rename(node, "theirs")])
        let entry = try #require(world.measure().entries.first)
        #expect(entry.kind == .sameRegister && entry.localWriteLost)
        let conflict = try #require(entry.properties.first)
        #expect(conflict.property == .register(Fixture.name))
        #expect(conflict.mine == .register(Fixture.nameValue("mine")))
        #expect(conflict.theirs == .register(Fixture.nameValue("theirs")))
        #expect(conflict.merged == .register(Fixture.nameValue("theirs")) && conflict.kept == .theirs)
        #expect(entry.localPaths == [Fixture.name] && entry.remotePaths == [Fixture.name] && entry.authors == [Divergent.priya])
        // Use mine re-asserts the local value as a fresh change that wins.
        let command = try #require(ReviewModel.useMine(entry))
        var state = world.state
        var builder = ChangeBuilder(replica: Divergent.me, startCounter: state.clock.peek)
        try command.execute(&builder, state: state)
        state.apply(Fixture.change(Divergent.me, seq: 99, start: builder.startCounter, builder.ops))
        #expect(state.register(node, Fixture.name)?.value == Fixture.nameValue("mine"))
    }

    @Test func aWonLocalWriteIsListedButNotLost() throws {
        var world = Divergent()
        let node = world.layers(1)[0]
        world.theirs([Fixture.rename(node, "theirs")])
        world.mine([Fixture.rename(node, "mine")])
        let entry = try #require(world.measure().entries.first)
        #expect(entry.kind == .sameRegister && !entry.localWriteLost && entry.properties[0].kept == .mine)
        #expect(ReviewModel.useMine(entry) == nil)
        // A third write kept by the merge is neither side's.
        #expect(Scope.side(OpID(counter: 99, replica: 3), OpID(counter: 1, replica: 1), OpID(counter: 2, replica: 2)) == .other)
        #expect(Scope.side(nil, nil, nil) == .other)
    }

    @Test func aStructWriteCoversItsFields() throws {
        var world = Divergent()
        let node = world.layers(1)[0]
        world.mine([Ops.set(node, [RegisterPath([150, 1])], values: Fixture.layer(name: "all", note: "all"))])
        world.theirs([Fixture.note(node, "theirs")])
        let entry = try #require(world.measure().entries.first)
        #expect(entry.kind == .sameRegister)
        #expect(entry.properties.map(\.property) == [.register(Fixture.note)])
        // A different field of the same object is only "both edited".
        var other = Divergent()
        let node2 = other.layers(1)[0]
        other.mine([Fixture.rename(node2, "a")])
        other.theirs([Fixture.note(node2, "b")])
        #expect(other.measure().entries[0].kinds == [.bothEdited])
    }

    @Test func aRemoteDeleteOfALocallyEditedObjectIsEditVersusDelete() throws {
        var world = Divergent()
        let node = world.layers(1)[0]
        world.mine([Fixture.rename(node, "mine")])
        world.theirs([Ops.setDeleted(node)])
        let entry = try #require(world.measure().entries.first)
        #expect(entry.kind == .editVsDelete && entry.actions == [.restore, .useTheirs])
        #expect(entry.properties == [PropertyConflict(property: .deleted, mine: nil, theirs: .flag(true), merged: .flag(true), kept: .theirs)])
        let restore = ReviewModel.restore(entry)
        #expect(restore.label == "Restore" && restore.ops == [Ops.setDeleted(node, false)])
        // The other way round: deleted here, edited there.
        var other = Divergent()
        let node2 = other.layers(1)[0]
        other.mine([Ops.setDeleted(node2)])
        other.theirs([Fixture.rename(node2, "theirs")])
        let second = try #require(other.measure().entries.first)
        #expect(second.kind == .editVsDelete && second.properties[0].kept == .mine)
        // Restored since: Use mine deletes again.
        other.theirs([Ops.setDeleted(node2, false)], by: Divergent.tom)
        let third = try #require(other.measure().entries.first)
        #expect(third.actions == [.useMine, .useTheirs] && third.kinds.contains(.sameRegister))
        #expect(ReviewModel.useMine(third)?.ops == [Ops.setDeleted(node2, true)])
    }

    @Test func deletingAnAncestorIsEditVersusDeleteOnTheEditedChild() throws {
        var world = Divergent()
        let parent = world.base([Fixture.createLayer("parent")])
        let child = world.base([Ops.create(parent: parent, position: [0x80], props: Fixture.layer(name: "child"))])
        world.mine([Fixture.rename(child, "edited")])
        world.theirs([Ops.setDeleted(parent)])
        let entries = world.measure().entries
        #expect(entries.count == 1)
        #expect(entries[0].node == child && entries[0].kind == .editVsDelete && entries[0].deletedAncestor == parent)
        #expect(entries[0].properties.isEmpty && entries[0].actions == [.useMine, .useTheirs])
        // And the other way: the parent deleted here, the child edited there.
        var other = Divergent()
        let parent2 = other.base([Fixture.createLayer("parent")])
        let child2 = other.base([Ops.create(parent: parent2, position: [0x80], props: Fixture.layer(name: "child"))])
        other.theirs([Fixture.rename(child2, "edited")])
        other.mine([Ops.setDeleted(parent2)])
        #expect(other.measure().entries.map(\.node) == [child2])
    }

    @Test func bothMovingAnObjectIsMoveVersusMove() throws {
        var world = Divergent()
        let nodes = world.layers(3)
        world.mine([Ops.move(nodes[0], parent: nodes[1], position: [0x80])])
        world.theirs([Ops.move(nodes[0], parent: nodes[2], position: [0x81])])
        let entry = try #require(world.measure().entries.first)
        #expect(entry.kind == .moveVsMove)
        let conflict = entry.properties[0]
        #expect(conflict.property == .placement && conflict.kept == .theirs)
        #expect(conflict.mine == .placement(parent: nodes[1], position: [0x80]))
        #expect(conflict.merged == .placement(parent: nodes[2], position: [0x81]))
        #expect(ReviewModel.useMine(entry)?.ops == [Ops.move(nodes[0], parent: nodes[1], position: [0x80])])
        // The later of two local moves is the one compared.
        world.mine([Ops.move(nodes[0], parent: nodes[1], position: [0x7F])])
        world.mine([Ops.move(nodes[0], parent: nodes[1], position: [0x7E])])
        #expect(world.measure().entries[0].properties[0].mine == .placement(parent: nodes[1], position: [0x7E]))
    }

    @Test func editsToTheSameParagraphAreSameText() throws {
        var world = Divergent()
        let block = world.base([Ops.create(parent: Fixture.layers, position: [0x80], props: Fixture.textBlock())])
        let text = world.base([Ops.textInsert(block, Fixture.text, "ab\ncd")])
        let newline = OpID(counter: text.counter + 2, replica: text.replica)
        let d = OpID(counter: text.counter + 4, replica: text.replica)
        // Mine types in the first paragraph; theirs formats the second.
        world.mine([Ops.textInsert(block, Fixture.text, "x", left: text, right: OpID(counter: text.counter + 1, replica: text.replica))])
        world.theirs([Ops.textDelete(block, Fixture.text, first: d, count: 1)])
        let separate = try #require(world.measure().entries.first)
        #expect(separate.kinds == [.bothEdited] && separate.paragraphs.isEmpty)
        // Theirs also sets the first paragraph's alignment (a paragraph register on the newline).
        var paragraph = Wiretuner_Doc_V1_NodeProps()
        paragraph.text.text.chars = [Wiretuner_Doc_V1_TextChar.with { $0.paragraph.alignment = Wiretuner_Doc_V1_Alignment(rawValue: 2)! }]
        world.theirs([Ops.set(block, [Fixture.text.element(newline).child(6).child(1)], values: paragraph)])
        let same = try #require(world.measure().entries.first)
        #expect(same.kind == .sameText)
        #expect(same.paragraphs == [ParagraphRef(text: Fixture.text, terminator: newline)])
    }

    @Test func textSpansMapToParagraphs() {
        var world = Divergent()
        let block = world.base([Ops.create(parent: Fixture.layers, position: [0x80], props: Fixture.textBlock())])
        let text = world.base([Ops.textInsert(block, Fixture.text, "a\nb\nc")])
        let index = ParagraphIndex(world.state.text(block, Fixture.text)!)
        let id = { (offset: UInt64) in OpID(counter: text.counter + offset, replica: text.replica) }
        #expect(index.terminators == [id(1), id(3), .zero])
        #expect(index.ordinals(CharSpan(from: id(0), to: id(4))) == 0...2)
        #expect(index.ordinals(CharSpan(from: .zero, to: .zero)) == 0...2)
        #expect(index.ordinals(CharSpan(from: id(4), to: OpID(counter: 999, replica: 5))) == 2...2)
        #expect(index.ordinals(CharSpan(from: OpID(counter: 999, replica: 5), to: id(2))) == 1...1)
        #expect(index.ordinals(CharSpan(from: OpID(counter: 999, replica: 5), to: OpID(counter: 998, replica: 5))) == nil)
        // A mark over the whole text touches every paragraph; the second side's edit is in the last.
        world.mine([markOp(block)])
        world.theirs([Ops.textInsert(block, Fixture.text, "!", left: id(4))])
        #expect(world.measure().entries[0].paragraphs.map(\.terminator) == [.zero])
    }

    private func markOp(_ block: OpID) -> Wiretuner_Doc_V1_Op {
        var mark = Wiretuner_Doc_V1_TextMark()
        mark.node = block.proto
        mark.text = Fixture.text.proto
        mark.start.before = true
        mark.value.size = 12
        var op = Wiretuner_Doc_V1_Op()
        op.textMark = mark
        return op
    }

    // MARK: Always and never listed

    @Test func commentThreadsAreNeverListed() {
        var world = Divergent()
        var thread = Wiretuner_Doc_V1_NodeProps()
        thread.commentThread = Wiretuner_Doc_V1_CommentThreadProps()
        let node = world.base([Ops.create(parent: .wellKnown(12), position: [0x80], props: thread)])
        world.mine([Ops.set(node, [RegisterPath([210, 6])], values: thread)])
        world.theirs([Ops.set(node, [RegisterPath([210, 6])], values: thread)])
        world.theirs([Ops.set(.wellKnown(12), [RegisterPath([1, 1, 1])], values: Wiretuner_Doc_V1_NodeProps())])
        let divergence = world.measure()
        #expect(divergence.entries.isEmpty && divergence.localObjects == 0 && divergence.remoteObjects == 0)
        #expect(divergence.decision(.standard) == .silentMerge)
    }

    @Test func aRemoteDeleteOfAnObjectWithAnOpenThreadIsListed() throws {
        var world = Divergent()
        let nodes = world.layers(3)
        func thread(_ anchor: OpID, resolved: Bool) -> Wiretuner_Doc_V1_NodeProps {
            var props = Wiretuner_Doc_V1_NodeProps()
            props.commentThread.anchor.id = anchor.proto
            props.commentThread.resolved = resolved
            return props
        }
        world.base([Ops.create(parent: .wellKnown(12), position: [0x80], props: thread(nodes[0], resolved: false))])
        world.base([Ops.create(parent: .wellKnown(12), position: [0x81], props: thread(nodes[1], resolved: true))])
        let deletedThread = world.base([Ops.create(parent: .wellKnown(12), position: [0x82], props: thread(nodes[2], resolved: false))])
        world.base([Ops.setDeleted(deletedThread)])
        world.base([Ops.create(parent: .wellKnown(12), position: [0x83], props: Fixture.layer(name: "not a thread"))])
        let elsewhere = world.base([Fixture.createLayer("elsewhere")])
        world.mine([Fixture.rename(elsewhere, "x")])
        world.theirs(nodes.map { Ops.setDeleted($0) })
        let entries = world.measure().entries
        #expect(entries.map(\.node) == [nodes[0]])
        #expect(entries[0].kind == .editVsDelete && entries[0].anchoredComment && entries[0].actions == [.restore, .useTheirs])
    }

    @Test func printSettingsTheOutputAreaAndViewStateAreNeverListed() {
        var world = Divergent()
        world.mine([Fixture.settings([2, 31]), Fixture.settings([2, 30]), Fixture.settings([2, 40])])
        world.theirs([Fixture.settings([2, 31, 1]), Fixture.settings([2, 30])])
        let divergence = world.measure()
        #expect(divergence.entries.isEmpty && divergence.localObjects == 0 && divergence.decision(.standard) == .silentMerge)
        // Other settings are ordinary registers of the settings node, listed when both wrote one;
        // two different settings are not an overlap (FONT-029).
        world.mine([Fixture.settings([2, 3])])
        world.theirs([Fixture.settings([2, 4])])
        #expect(world.measure().entries.isEmpty)
        world.theirs([Fixture.settings([2, 3])])
        #expect(world.measure().entries.map(\.kind) == [.sameRegister])
    }

    @Test func remoteColorSettingsAreAlwaysListed() throws {
        var world = Divergent()
        let nodes = world.layers(2)
        world.mine([Fixture.rename(nodes[0], "mine")])
        world.theirs([Fixture.settings([2, 50, 1])])
        let divergence = world.measure(gap: Self.apart)
        #expect(divergence.overlapCount == 0 && divergence.decision(.standard) == .perObject)
        let entry = try #require(divergence.entries.first)
        #expect(entry.setting == .colorSettings && entry.actions == [.useTheirs] && entry.authors == [Divergent.priya])
        #expect(entry.id == "setting:colorSettings" && DocumentSetting.colorSettings.title == "Color settings")
        world.mine([Fixture.settings([2, 50, 2])])
        #expect(world.measure().entries.first { $0.setting != nil }?.actions == [.useMine, .useTheirs])
    }

    @Test func aRemoteFontMetricChangeOverlapsEveryLocallyTouchedGlyph() {
        var world = Divergent()
        var glyph = Wiretuner_Doc_V1_NodeProps()
        glyph.glyph.name = "a"
        let a = world.base([Ops.create(parent: .wellKnown(11), position: [0x80], props: glyph)])
        let layer = world.layers(1)[0]
        world.mine([Ops.set(a, [RegisterPath([220, 2])], values: glyph), Fixture.rename(layer, "x")])
        world.theirs([Fixture.settings([2, 21, 2])])
        let entries = world.measure().entries
        #expect(entries.map(\.setting) == [.fontMetrics, nil])
        #expect(entries[1].node == a && entries[1].kind == .bothEdited)
        #expect(DocumentSetting.fontMetrics.title == "Font metrics")
        world.theirs([Fixture.settings([2, 20])], by: Divergent.tom)
        #expect(world.measure().entries[0].authors == [Divergent.priya, Divergent.tom])
    }

    @Test func sequenceElementsWrittenOnBothSidesAreTheSameRegister() throws {
        var world = Divergent()
        let sizes = RegisterPath([2, 5])
        var page = Wiretuner_Doc_V1_NodeProps()
        page.settings.customPageSizes = [Wiretuner_Doc_V1_CustomPageSize.with { $0.name = "A" }]
        let element = world.base([Ops.elementInsert(.wellKnown(1), sizes, positions: [[0x80]], values: page)])
        let path = sizes.element(element)
        world.mine([Ops.elementMove(.wellKnown(1), path, position: [0x70]), Ops.elementDelete(.wellKnown(1), [path], deleted: false)])
        world.theirs([Ops.elementMove(.wellKnown(1), path, position: [0x90]), Ops.elementDelete(.wellKnown(1), [path])])
        let entry = try #require(world.measure().entries.first)
        #expect(entry.kind == .sameRegister)
        #expect(entry.properties.map(\.property) == [.elementPosition(path), .elementDeleted(path)])
        #expect(entry.properties.allSatisfy { $0.kept == .theirs })
        #expect(ReviewModel.useMine(entry)?.ops == [Ops.elementMove(.wellKnown(1), path, position: [0x70]),
                                                     Ops.elementDelete(.wellKnown(1), [path], deleted: false)])
        // Inserting into the same sequence and writing sets on both sides is only "both edited" --
        // which the settings node, a holder of independent settings, never is (FONT-029).
        var other = Divergent()
        let layer = other.layers(1)[0]
        var tags = Wiretuner_Doc_V1_NodeProps()
        tags.settings.customPageSizes = [Wiretuner_Doc_V1_CustomPageSize.with { $0.name = "B" }]
        other.mine([Ops.elementInsert(.wellKnown(1), sizes, positions: [[0x81]], values: tags),
                    Ops.setAdd(layer, RegisterPath([150, 1, 30]), values: Wiretuner_Doc_V1_NodeProps())])
        other.theirs([Ops.elementInsert(.wellKnown(1), sizes, positions: [[0x82]], values: tags),
                      Ops.setRemove(layer, RegisterPath([150, 1, 30]), values: Wiretuner_Doc_V1_NodeProps())])
        #expect(other.measure().entries.map(\.kinds) == [[.bothEdited]] && other.measure().entries.map(\.node) == [layer])
    }

    @Test func noopsAndUnreadablePathsCountForNothing() {
        var world = Divergent()
        var set = Wiretuner_Doc_V1_SetFields()
        set.node = OpID.wellKnown(0).proto
        set.paths = [Wiretuner_Doc_V1_FieldPath()]
        var op = Wiretuner_Doc_V1_Op()
        op.set = set
        var move = Wiretuner_Doc_V1_ElementMove()
        move.node = OpID.wellKnown(1).proto
        var unreadable = Wiretuner_Doc_V1_Op()
        unreadable.elementMove = move
        var insert = Wiretuner_Doc_V1_TextInsert()
        insert.node = OpID.wellKnown(0).proto
        var noText = Wiretuner_Doc_V1_Op()
        noText.textInsert = insert
        var delete = Wiretuner_Doc_V1_TextDelete()
        delete.node = OpID.wellKnown(0).proto
        var noDelete = Wiretuner_Doc_V1_Op()
        noDelete.textDelete = delete
        var mark = Wiretuner_Doc_V1_TextMark()
        mark.node = OpID.wellKnown(0).proto
        var noMark = Wiretuner_Doc_V1_Op()
        noMark.textMark = mark
        world.mine([Ops.noop(), op, unreadable, noText, noDelete, noMark])
        let divergence = world.measure()
        #expect(divergence.localOps == 5 && divergence.localObjects == 0)
    }

    /// TEST-001 finding (c), D-070: a connection dropped for minutes while people edit the same
    /// objects merges and uploads, offering the overlap read-only; offline work, a large outbox or
    /// *Always ask* asks as before.
    @Test func aBriefDropNeverHoldsTheOutbox() {
        var world = Divergent()
        let nodes = world.layers(30)
        for node in nodes {
            world.mine([Fixture.rename(node, "mine")])
            world.theirs([Fixture.rename(node, "theirs")])
        }
        let brief = world.measure(gap: .seconds(20))
        #expect(brief.isBrief(.standard) && brief.decision(.standard) == .suggestReview)
        #expect(ReviewModel(brief, decision: .suggestReview).entries.count == 30)
        #expect(brief.decision(ReconcilePreferences(alwaysAsk: true)) == .wholeDocument)
        #expect(brief.decision(ReconcilePreferences(autoMergeBelow: 30)) == .wholeDocument)
        #expect(world.measure(gap: .seconds(15 * 60)).decision(.standard) == .wholeDocument)
        #expect(brief.decision(ReconcilePreferences(briefGap: .seconds(10))) == .wholeDocument)
        // Nothing in common: the ordinary rules, silent here.
        var apart = Divergent()
        let two = apart.layers(2)
        apart.mine([Fixture.rename(two[0], "a")])
        apart.theirs([Fixture.rename(two[1], "b")])
        #expect(apart.measure(gap: .seconds(20)).decision(.standard) == .silentMerge)
    }

    // MARK: Preferences and the model

    @Test func teamFloorsTakeTheStricterValue() {
        let user = ReconcilePreferences(autoMergeBelow: 800, askOverlapCount: 10, askOverlapShare: 0.1, alwaysAsk: false,
                                        suggestReviewAfter: .seconds(3600), briefGap: .seconds(600), shareMinimum: 8)
        let team = ReconcilePreferences(autoMergeBelow: 400, askOverlapCount: 30, askOverlapShare: 0.5, alwaysAsk: true,
                                        suggestReviewAfter: .seconds(7200))
        #expect(user.floored(by: team) == ReconcilePreferences(autoMergeBelow: 400, askOverlapCount: 30, askOverlapShare: 0.5,
                                                               alwaysAsk: true, suggestReviewAfter: .seconds(7200),
                                                               briefGap: .seconds(900), shareMinimum: 8))
        #expect(ReconcileDecision.perObject.holdsOutbox && ReconcileDecision.wholeDocument.holdsOutbox)
        #expect(!ReconcileDecision.silentMerge.holdsOutbox && !ReconcileDecision.suggestReview.holdsOutbox)
    }

    @Test func kindsReadAsTheSheetWordsThem() {
        #expect(OverlapKind.allCases.map(\.title) == ["Edited and deleted", "Same attribute", "Same text", "Both moved", "Both edited"])
        #expect(OverlapKind.editVsDelete < .bothEdited)
        #expect(ReviewEntry(node: .zero, kinds: []).kind == .bothEdited)
        let properties: [ReviewProperty] = [.elementDeleted(RegisterPath([2])), .register(RegisterPath([3])), .placement, .deleted,
                                            .elementPosition(RegisterPath([1])), .register(RegisterPath([1]))]
        #expect(properties.sorted() == [.deleted, .placement, .register(RegisterPath([1])), .register(RegisterPath([3])),
                                        .elementPosition(RegisterPath([1])), .elementDeleted(RegisterPath([2]))])
        #expect(!(ReviewProperty.deleted < .deleted))
    }

    @Test func aRecoveredReviewNamesWhatSalvageDid() {
        let report = SalvageReport(reason: .expired, salvagedChanges: 3, recoveredChanges: 2, reissuedOps: 5)
        let review = ReviewModel(recovered: report)
        #expect(review.mode == .recovered && review.holdsOutbox && review.localOps == 5 && review.recovered == report)
        #expect(review.documentActions == [.keepMerged, .keepBranch])
        #expect(SparseProps.wrap(Fixture.name, nil) == Wiretuner_Doc_V1_NodeProps())
        #expect(BulkFrames.varintBytes(300) == [0xAC, 0x02])
    }
}
