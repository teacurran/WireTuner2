import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// COLLAB-021: restore as a change (history.adoc, "Merge semantics").
@Suite struct RestoreTests {
    struct Scene {
        var rect = OpID.zero
        var path = OpID.zero
        var text = OpID.zero
        var thread = OpID.zero
    }

    static let keywords = RegisterPath([2, 130, 4])

    static func keyword(_ values: [String]) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.settings.info.keywords = values
        return props
    }

    static func size(_ points: Double) -> Wiretuner_Doc_V1_TextMarkValue {
        var value = Wiretuner_Doc_V1_TextMarkValue()
        value.size = points
        return value
    }

    /// A document with a rectangle, a two-contour path, a text block with formatting, keywords
    /// and a comment thread.
    static func build(_ replica: inout Replica) throws -> Scene {
        var scene = Scene()
        scene.rect = try replica.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 10)))!.createdObjects[0]
        let path = CreatePath(contours: [NewContour(closed: true, points: PathFixture.points([(0, 0), (10, 0), (10, 10)])),
                                         NewContour(points: PathFixture.points([(50, 50), (60, 60)]))])
        scene.path = try replica.perform(path)!.createdObjects[0]
        scene.text = try replica.perform(CreateTextBlock(.point(Point(x: 5, y: 5)), text: "Hello world\nSecond line"))!.createdObjects[0]
        let text = try #require(TextNode(scene.text, in: replica.state))
        try replica.perform(ApplyMark(node: scene.text, from: text.anchor(at: 0), to: text.anchor(at: 5), value: size(18)))
        try replica.perform(OpsCommand("Keywords", ops: [Ops.setAdd(WellKnown.settings, keywords, values: keyword(["logo", "draft"]))]))
        scene.thread = try CommentTests.thread(&replica, on: scene.rect)
        return scene
    }

    /// Edits of every kind after the version.
    static func edit(_ replica: inout Replica, _ scene: Scene) throws -> OpID {
        try replica.perform(SetTransforms([(scene.rect, WTGeometry.AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 99, ty: 1))]))
        try replica.perform(SetNameOrNote([scene.path], .name, "Renamed"))
        let contours = replica.state.liveElements(scene.path, PathFields.contours)
        let points = replica.state.liveElements(scene.path, PathFields.points(contours[0]))
        try replica.perform(OpsCommand("Edit points", ops: [
            Ops.elementDelete(scene.path, [PathFields.point(contours[0], points[1])]),
            Ops.elementDelete(scene.path, [PathFields.contour(contours[1])]),
            Ops.elementMove(scene.path, PathFields.point(contours[0], points[2]), position: [0x10]),
        ]))
        let text = try #require(TextNode(scene.text, in: replica.state))
        try replica.perform(DeleteText(node: scene.text, from: text.anchor(at: 2), to: text.anchor(at: 9)))
        let edited = try #require(TextNode(scene.text, in: replica.state))
        try replica.perform(InsertText(node: scene.text, text: "XYZ", at: edited.anchor(at: 1)))
        let again = try #require(TextNode(scene.text, in: replica.state))
        try replica.perform(ApplyMark(node: scene.text, from: again.anchor(at: 0), to: again.anchor(at: again.length), value: size(30)))
        try replica.perform(OpsCommand("Keywords", ops: [Ops.setRemove(WellKnown.settings, keywords, values: keyword(["draft"])),
                                                         Ops.setAdd(WellKnown.settings, keywords, values: keyword(["final"]))]))
        try replica.perform(DeleteNodes([scene.rect]))
        let added = try replica.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5)))!.createdObjects[0]
        try replica.perform(Reply(to: scene.thread, author: "sam", body: CommentBody("since the version")))
        _ = try CommentTests.thread(&replica, text: "A newer thread")
        return added
    }

    @Test func restoreBringsBackTheVersionsContentAsOneChange() throws {
        var replica = Replica(0xA)
        let scene = try Self.build(&replica)
        let version = replica.state
        let added = try Self.edit(&replica, scene)
        #expect(RestoreContent.hash(replica.state) != RestoreContent.hash(version))
        let summary = RestoreCommand.summary(target: version, current: replica.state)
        #expect(summary.broughtBack == 1 && summary.deletedSinceVersion == 1 && summary.unrestorable == 0)
        #expect(summary.changed == 3)
        #expect(summary.sentence == "This will change 3 objects, delete 1 object added since, and bring back 1 deleted object.")
        let before = RestoreContent.hash(replica.state)
        let command = RestoreCommand(target: version, name: "Client review 2")
        #expect(command.label == "Restore 'Client review 2'")
        let change = try #require(try replica.perform(command))
        #expect(change.label == "Restore 'Client review 2'")
        #expect(RestoreContent.hash(replica.state) == RestoreContent.hash(version))
        #expect(replica.state.isLive(scene.rect) && !replica.state.isLive(added))
        // Comments are left alone: the newer thread and the reply stay.
        let threads = CommentThreadModel(replica.state)
        #expect(threads.threads.count == 2)
        #expect(threads[scene.thread]?.replies.count == 1)
        // One undo step takes it back.
        #expect(replica.undo() != nil)
        #expect(RestoreContent.hash(replica.state) == before)
        // Restoring again (elements and characters re-inserted under fresh ids read as new) keeps the content.
        try replica.perform(RestoreCommand(target: version, name: "again"))
        #expect(RestoreContent.hash(replica.state) == RestoreContent.hash(version))
    }

    /// A concurrent remote edit to a restored register resolves by OpId, both replicas converge,
    /// and undoing the restore reverts only registers still holding restored values.
    @Test func restoreMergesWithConcurrentEditsAndUndoKeepsOthersWork() throws {
        var pair = Pair()
        let scene = try Self.build(&pair.a)
        pair.sync()
        let version = pair.a.state
        let moved = WTGeometry.AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 40, ty: 0)
        try pair.a.perform(SetTransforms([(scene.rect, moved)]))
        try pair.a.perform(SetNameOrNote([scene.path], .name, "Changed"))
        pair.sync()
        // A restores while B renames the path and moves the rectangle.
        let restore = try #require(try pair.a.perform(RestoreCommand(target: version, name: "v1")))
        let rename = try #require(try pair.b.perform(SetNameOrNote([scene.path], .name, "By B")))
        try pair.b.perform(SetTransforms([(scene.rect, WTGeometry.AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 7, ty: 7))]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        // Whichever write has the greater OpId holds the name on both.
        let restoreWins = pair.a.state.store.register(scene.path, PathFields.name)?.op.replica == restore.replica
        #expect(rename.replica == 0xB)
        #expect(NodeValues.common(pair.a.state.props(scene.path))?.name == (restoreWins ? "" : "By B"))
        // B's later edit to the rectangle stands through A's undo; the path's name, if still A's, reverts.
        try pair.b.perform(SetTransforms([(scene.rect, WTGeometry.AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 3, ty: 3))]))
        pair.sync()
        #expect(pair.a.undo() != nil)
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(Objects.transform(of: scene.rect, in: pair.a.state).tx == 3)
        #expect(NodeValues.common(pair.a.state.props(scene.path))?.name == (restoreWins ? "Changed" : "By B"))
    }

    @Test func summarySentences() {
        var summary = RestoreSummary()
        #expect(summary.sentence == "The document already matches this version.")
        summary.changed = 1
        #expect(summary.sentence == "This will change 1 object.")
        summary.broughtBack = 2
        #expect(summary.sentence == "This will change 1 object, and bring back 2 deleted objects.")
        #expect(!summary.isEmpty)
        #expect(!RestoreSummary().isEmpty == false)
        var deleting = RestoreSummary()
        deleting.deletedSinceVersion = 1
        #expect(!deleting.isEmpty)
        var bringing = RestoreSummary()
        bringing.broughtBack = 1
        #expect(!bringing.isEmpty)
    }

    @Test func aNodeCompactedOutIsNotRestored() throws {
        var author = Replica(0xA)
        let scene = try Self.build(&author)
        var server = DocumentCore(state: EngineState(), replica: 0xB)
        var seq: UInt64 = 0
        for change in author.sent {
            seq += 1
            server.receive(change, serverSeq: seq)
        }
        let version = server.state
        try author.perform(DeleteNodes([scene.path]))
        server.receive(author.sent.last!, serverSeq: seq + 1)
        var pruned = server.state
        _ = pruned.collect(stableSeq: seq + 1, now: Int64.max / 2)
        #expect(!pruned.store.exists(scene.path))
        let summary = RestoreCommand.summary(target: version, current: pruned)
        #expect(summary.unrestorable == 1)
    }

    /// Restores on documents whose tombstones were collected never name a collected id, and give
    /// back the version's content.
    @Test func restoresNeverNameACollectedTombstone() throws {
        for seed in UInt64(1)...12 {
            var random = SplitMix64(seed: seed)
            var author = Replica(0xA)
            let scene = try Self.build(&author)
            try Self.shuffle(&author, scene, &random, steps: 20)
            var server = DocumentCore(state: EngineState(), replica: 0xB)
            var seq: UInt64 = 0
            var delivered = 0
            func deliver() {
                for change in author.sent[delivered...] {
                    seq += 1
                    server.receive(change, serverSeq: seq)
                }
                delivered = author.sent.count
            }
            deliver()
            let version = server.state
            try Self.shuffle(&author, scene, &random, steps: 40)
            deliver()
            var pruned = server.state
            _ = pruned.collect(stableSeq: seq, now: 0)
            var builder = ChangeBuilder(replica: 0xC, startCounter: pruned.clock.peek)
            var diff = RestoreDiff(target: version, current: pruned, horizon: seq)
            diff.emit(into: &builder)
            let change = Fixture.change(0xC, seq: 1, start: builder.startCounter, builder.ops)
            Self.expectKnown(change, in: pruned, seed: seed)
            pruned.apply(change)
            #expect(RestoreContent.hash(pruned) == RestoreContent.hash(version), "seed \(seed)")
        }
    }

    static func shuffle(_ replica: inout Replica, _ scene: Scene, _ random: inout SplitMix64, steps: Int) throws {
        for _ in 0..<steps {
            let text = try #require(TextNode(scene.text, in: replica.state))
            switch random.next() % 6 {
            case 0, 1:
                let offset = Int(random.next() % UInt64(text.length + 1))
                try replica.perform(InsertText(node: scene.text, text: ["a", "bc", "\n", "d"][Int(random.next() % 4)], at: text.anchor(at: offset)))
            case 2 where text.length > 2:
                let start = Int(random.next() % UInt64(text.length - 1))
                let end = min(text.length, start + 1 + Int(random.next() % 3))
                try replica.perform(DeleteText(node: scene.text, from: text.anchor(at: start), to: text.anchor(at: end)))
            case 3 where text.length > 0:
                let end = 1 + Int(random.next() % UInt64(text.length))
                try replica.perform(ApplyMark(node: scene.text, from: text.anchor(at: 0), to: text.anchor(at: end), value: size(Double(8 + random.next() % 20))))
            case 4:
                let contours = replica.state.liveElements(scene.path, PathFields.contours)
                if let contour = contours.first {
                    let points = replica.state.liveElements(scene.path, PathFields.points(contour))
                    if points.count > 1 {
                        let point = points[Int(random.next() % UInt64(points.count))]
                        try replica.perform(OpsCommand("delete point", ops: [Ops.elementDelete(scene.path, [PathFields.point(contour, point)])]))
                    } else {
                        try replica.perform(OpsCommand("add point", ops: [Ops.elementInsert(scene.path, PathFields.points(contour), positions: [[0x90, UInt8(random.next() % 200)]])]))
                    }
                }
            default:
                try replica.perform(SetTransforms([(scene.rect, WTGeometry.AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: Double(random.next() % 100), ty: 0))]))
            }
        }
    }

    /// Every id `change` names exists in `state`, or is made by the change itself.
    static func expectKnown(_ change: Wiretuner_Doc_V1_Change, in state: EngineState, seed: UInt64) {
        let own = { (id: OpID) in id.replica == change.replica && id.counter >= change.startCounter }
        func known(_ node: OpID, text path: Wiretuner_Doc_V1_FieldPath, _ id: Wiretuner_Doc_V1_ElementId) -> Bool {
            let char = OpID(counter: id.counter, replica: id.replica)
            guard char != .zero, !own(char) else { return true }
            return RegisterPath(path).flatMap { state.store.text(node, $0) }?.contains(char) == true
        }
        func elementKnown(_ node: OpID, _ path: Wiretuner_Doc_V1_FieldPath) -> Bool {
            guard let path = RegisterPath(path) else { return false }
            var prefix: [RegisterPath.Segment] = []
            for segment in path.segments {
                prefix.append(segment)
                if case .element(let id) = segment, !own(id) {
                    let at = RegisterPath(segments: prefix)
                    if state.store.element(node, at) == nil && !(at.parent.flatMap { state.store.text(node, $0) }?.contains(id) ?? false) {
                        return false
                    }
                }
            }
            return true
        }
        for op in change.ops {
            switch op.op {
            case .set(let set):
                #expect(state.store.exists(OpID(set.node)), "seed \(seed)")
                #expect(set.paths.allSatisfy { elementKnown(OpID(set.node), $0) }, "seed \(seed)")
            case .move(let move):
                #expect(state.store.exists(OpID(move.node)) && state.store.exists(OpID(move.parent)), "seed \(seed)")
            case .setDeleted(let setDeleted):
                #expect(state.store.exists(OpID(setDeleted.node)), "seed \(seed)")
            case .elementInsert(let insert):
                #expect(elementKnown(OpID(insert.node), insert.sequence), "seed \(seed)")
            case .elementMove(let move):
                #expect(elementKnown(OpID(move.node), move.element), "seed \(seed)")
            case .elementDelete(let delete):
                #expect(delete.elements.allSatisfy { elementKnown(OpID(delete.node), $0) }, "seed \(seed)")
            case .textInsert(let insert):
                let node = OpID(insert.node)
                #expect(known(node, text: insert.text, insert.leftOrigin) && known(node, text: insert.text, insert.rightOrigin), "seed \(seed)")
            case .textDelete(let delete):
                #expect(delete.ranges.allSatisfy { known(OpID(delete.node), text: delete.text, $0.first) }, "seed \(seed)")
            case .textMark(let mark):
                let node = OpID(mark.node)
                #expect(known(node, text: mark.text, mark.start.char) && known(node, text: mark.text, mark.end.char), "seed \(seed)")
            default:
                break
            }
        }
    }

    /// A richer version: paragraph registers on a newline, an empty text block typed into later,
    /// a Corners effect with its point set, reordering, element registers and several keywords.
    @Test func restoreCoversParagraphsSetsInsideElementsAndOrder() throws {
        var replica = Replica(0xA)
        let scene = try Self.build(&replica)
        var paragraph = Wiretuner_Doc_V1_ParagraphProps()
        paragraph.alignment = .center
        let styled = try replica.perform(CreateTextBlock(.point(Point(x: 1, y: 1)), text: "One\nTwo\nThree", paragraph: paragraph))!.createdObjects[0]
        let empty = try replica.perform(CreateTextBlock(.point(Point(x: 9, y: 9))))!.createdObjects[0]
        try replica.perform(AddEffect([scene.path], kind: .corners))
        let row = EffectReading.entries(scene.path, in: replica.state)[0].row
        let contours = replica.state.liveElements(scene.path, PathFields.contours)
        let points = replica.state.liveElements(scene.path, PathFields.points(contours[0]))
        try replica.perform(SetCornerPoints([(scene.path, row)], points: [points[0], points[1]], adding: true))
        try replica.perform(OpsCommand("Keywords", ops: [Ops.setAdd(WellKnown.settings, Self.keywords, values: Self.keyword(["a", "b"]))]))
        let version = replica.state
        // Edits: the newlines go, the empty block is typed into, the effect goes, the path moves
        // below the rectangle and one of its anchors moves, keywords change.
        let text = try #require(TextNode(styled, in: replica.state))
        try replica.perform(DeleteText(node: styled, from: text.anchor(at: 2), to: text.anchor(at: 9)))
        try replica.perform(InsertText(node: empty, text: "late", at: .start))
        try replica.perform(RemoveEffect([(scene.path, row)]))
        let layer = try #require(replica.state.store.placement(scene.path)?.parent)
        try replica.perform(OpsCommand("Reorder", ops: [Ops.move(scene.path, parent: layer, position: [0x01])]))
        var point = Wiretuner_Doc_V1_PathPoint()
        point.anchor = PathEditing.proto(Point(x: 5, y: 5))
        try replica.perform(OpsCommand("Nudge", ops: [Ops.set(scene.path, [PathFields.anchor(contours[0], points[0])], values: PathEditing.pointValues(point))]))
        try replica.perform(OpsCommand("Keywords", ops: [Ops.setRemove(WellKnown.settings, Self.keywords, values: Self.keyword(["a", "b"])),
                                                         Ops.setAdd(WellKnown.settings, Self.keywords, values: Self.keyword(["c", "d"]))]))
        #expect(RestoreContent.hash(replica.state) != RestoreContent.hash(version))
        try replica.perform(RestoreCommand(target: version, name: "rich"))
        #expect(RestoreContent.hash(replica.state) == RestoreContent.hash(version))
        #expect(EffectReading.entries(scene.path, in: replica.state).first?.effect.settings.corners.points.count == 2)
        #expect(TextNode(empty, in: replica.state)?.string == "")
    }

    @Test func setMembersAreEncodedByType() throws {
        let path = RegisterPath([2, 130, 4])
        let values = try #require(RestoreValues.members([Array("x".utf8)], at: path, schema: .generated))
        #expect(values.settings.info.keywords == ["x"])
        #expect(RestoreValues.members([[1]], at: RegisterPath([2, 9_999]), schema: .generated) == nil)
        let id = [UInt8](repeating: 0, count: 7) + [5] + [UInt8](repeating: 0, count: 7) + [9]
        #expect(RestoreValues.record(id, number: 3, type: "message") == Wire.field(3, Wire.elementID(OpID(counter: 5, replica: 9))))
        #expect(RestoreValues.record([1, 2, 3, 4, 5, 6, 7, 8], number: 1, type: "double") == [0x09, 1, 2, 3, 4, 5, 6, 7, 8])
        #expect(RestoreValues.record([1, 2, 3, 4], number: 1, type: "fixed32") == [0x0D, 1, 2, 3, 4])
        #expect(RestoreValues.record([0, 0, 0, 0, 0, 0, 0, 7], number: 2, type: "uint32") == [0x10, 7])
    }
}
