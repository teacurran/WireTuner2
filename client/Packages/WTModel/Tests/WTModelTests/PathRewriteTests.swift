import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// `RewritePath` (DRAW-018, DRAW-027, DRAW-028): kept points keep their ids and write only what
/// changed, new points go in their place, pieces become new nodes; and `DisplayNames`/`AppendNote`
/// (OBJ-021).
@Suite struct PathRewriteTests {
    static func square() -> CreatePath { PathFixture.closed([(0, 0), (10, 0), (10, 10), (0, 10)]) }

    @Test func keptPointsWriteOnlyWhatChangedAndNewPointsGoInPlace() throws {
        var replica = Replica(1)
        let (node, contour) = PathFixture.ids(try replica.perform(PathFixture.open([(0, 0), (10, 0), (20, 0), (30, 0)])), in: replica.state)
        let drawn = replica.path(node).contour(contour)!.drawn
        var moved = drawn[1]
        moved.anchor = Point(x: 10, y: 5)
        let inserted = VectorPoint(anchor: Point(x: 15, y: 9))
        let edit = RewritePath.ContourEdit(contour: contour, points: [drawn[0], moved, inserted, drawn[3]], closed: false)
        let change = try #require(try replica.perform(RewritePath(node: node, edits: [edit], label: "Freeform")))
        #expect(change.label == "Freeform")
        let after = replica.path(node).contour(contour)!
        #expect(PathFixture.anchors(after) == [Point(x: 0, y: 0), Point(x: 10, y: 5), Point(x: 15, y: 9), Point(x: 30, y: 0)])
        #expect(after.drawn[0].id == drawn[0].id && after.drawn[1].id == drawn[1].id && after.drawn[3].id == drawn[3].id)
        #expect(!after.closed)
        // Deleting, setting and inserting: one delete, one anchor set, one insert.
        let kinds = change.ops.map { op -> String in
            switch op.op {
            case .elementDelete?: "delete"
            case .set?: "set"
            case .elementInsert?: "insert"
            default: "other"
            }
        }
        #expect(kinds.sorted() == ["delete", "insert", "set"])
        // Unchanged points write nothing at all.
        let same = RewritePath.ContourEdit(contour: contour, points: after.drawn, closed: false)
        #expect(try replica.perform(RewritePath(node: node, edits: [same], label: "Nothing")) == nil)
    }

    @Test func handlesKindsAndClosingAreWritten() throws {
        var replica = Replica(1)
        let (node, contour) = PathFixture.ids(try replica.perform(PathFixture.open([(0, 0), (10, 0), (20, 0)])), in: replica.state)
        var drawn = replica.path(node).contour(contour)!.drawn
        drawn[1].kind = .curve
        drawn[1].inHandle = Vector(dx: -3, dy: 0)
        drawn[1].outHandle = Vector(dx: 3, dy: 0)
        drawn[2].automatic = true
        _ = try replica.perform(RewritePath(node: node, edits: [.init(contour: contour, points: drawn, closed: true)], label: "Edit"))
        let after = replica.path(node).contour(contour)!
        #expect(after.closed)
        let middle = try #require(after.points.first { $0.id == drawn[1].id })
        #expect(middle.kind == .curve && middle.inHandle == Vector(dx: -3, dy: 0) && middle.outHandle == Vector(dx: 3, dy: 0))
        #expect(after.points.first { $0.id == drawn[2].id }?.automatic == true)
    }

    @Test func pointsOutOfOrderAreWrittenAsNewOnesAndStartFollowsTheHead() throws {
        var replica = Replica(1)
        let (node, contour) = PathFixture.ids(try replica.perform(PathFixture.open([(0, 0), (10, 0), (20, 0)])), in: replica.state)
        let drawn = replica.path(node).contour(contour)!.drawn
        let reversed = Array(drawn.reversed())
        #expect(!RewritePath.keepsOrder(reversed, drawn: drawn, closed: false))
        _ = try replica.perform(RewritePath(node: node, edits: [.init(contour: contour, points: reversed, closed: false)], label: "Reverse"))
        let after = replica.path(node).contour(contour)!
        #expect(PathFixture.anchors(after) == [Point(x: 20, y: 0), Point(x: 10, y: 0), Point(x: 0, y: 0)])
        #expect(Set(after.points.map(\.id)).isDisjoint(with: drawn.map(\.id)))
        // A new head point before the kept ones becomes the start.
        let head = VectorPoint(anchor: Point(x: -10, y: 0))
        _ = try replica.perform(RewritePath(node: node, edits: [.init(contour: contour, points: [head] + after.drawn, closed: false)], label: "Extend"))
        #expect(PathFixture.anchors(replica.path(node).contour(contour)!).first == Point(x: -10, y: 0))
        // Cyclic order on a closed contour: one wrap is still in order, two are not.
        let square = PathFixture.points([(0, 0), (1, 0), (1, 1), (0, 1)]).enumerated().map { index, point -> VectorPoint in
            var copy = point
            copy.id = OpID(counter: UInt64(index + 1), replica: 1)
            return copy
        }
        #expect(RewritePath.keepsOrder([square[2], square[3], square[0]], drawn: square, closed: true))
        #expect(!RewritePath.keepsOrder([square[2], square[0], square[3]], drawn: square, closed: true))
        #expect(RewritePath.keepsOrder([square[1]], drawn: square, closed: true))
    }

    @Test func piecesAreNewNodesJustAboveWithTheAttributesAndContoursComeAndGo() throws {
        var replica = Replica(1)
        let (node, contour) = PathFixture.ids(try replica.perform(Self.square()), in: replica.state)
        let piece = [NewContour(points: PathFixture.points([(20, 0), (30, 0)]))]
        let extra = NewContour(closed: true, points: PathFixture.points([(2, 2), (4, 2), (4, 4)]))
        let change = try #require(try replica.perform(RewritePath(node: node, added: [extra], pieces: [piece, piece], label: "Knife")))
        #expect(change.createdObjects.count == 2)
        let path = replica.path(node)
        #expect(path.contours.count == 2)
        for created in change.createdObjects {
            #expect(replica.state.nodeKind(created) == .path)
            #expect(PathFixture.anchors(replica.path(created).contours[0]) == [Point(x: 20, y: 0), Point(x: 30, y: 0)])
            #expect(replica.state.props(created).path.appearance.strokes.count == replica.state.props(node).path.appearance.strokes.count)
        }
        // The pieces sit directly above the source, below anything that was above it.
        let parent = try #require(replica.state.store.placement(node)?.parent)
        let children = replica.state.liveChildren(parent)
        #expect(children.firstIndex(of: node)! < children.firstIndex(of: change.createdObjects[0])!)
        _ = try replica.perform(RewritePath(node: node, removed: [contour], label: "Remove"))
        #expect(replica.path(node).contours.count == 1)
        #expect(throws: PathEditError.self) { try replica.perform(RewritePath(node: node, removed: [contour], label: "Again")) }
        #expect(throws: PathEditError.self) {
            try replica.perform(RewritePath(node: node, edits: [.init(contour: contour, points: [], closed: false)], label: "Gone"))
        }
        let bad = VectorPoint(anchor: Point(x: .nan, y: 0))
        let live = replica.path(node).contours[0].id
        #expect(throws: PathEditError.self) { try replica.perform(RewritePath(node: node, edits: [.init(contour: live, points: [bad], closed: false)], label: "NaN")) }
        let many = Array(repeating: VectorPoint(anchor: .zero), count: VectorContour.maximumPoints + 1)
        #expect(throws: PathEditError.self) { try replica.perform(RewritePath(node: node, edits: [.init(contour: live, points: many, closed: false)], label: "Many")) }
    }

    @Test func aConcurrentEditOfAKeptPointSurvivesAndOfADeletedPointLandsOnItsTombstone() throws {
        var pair = Pair()
        let (node, contour) = PathFixture.ids(try pair.a.perform(PathFixture.open([(0, 0), (10, 0), (20, 0), (30, 0)])), in: pair.a.state)
        pair.sync()
        let drawn = pair.a.path(node).contour(contour)!.drawn
        // A keeps points 0, 1 and 3 (moving none of them) and replaces 2 with a new point.
        let edit = RewritePath.ContourEdit(contour: contour, points: [drawn[0], drawn[1], VectorPoint(anchor: Point(x: 22, y: 4)), drawn[3]], closed: false)
        _ = try pair.a.perform(RewritePath(node: node, edits: [edit], label: "Freeform"))
        // B moves point 1 (kept) and point 2 (deleted by A).
        _ = try pair.b.perform(MovePoints(node: node, contour: contour, point: drawn[1].id, to: Point(x: 10, y: -7)))
        _ = try pair.b.perform(MovePoints(node: node, contour: contour, point: drawn[2].id, to: Point(x: 20, y: -7)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let merged = pair.a.path(node).contour(contour)!
        #expect(PathFixture.anchors(merged) == [Point(x: 0, y: 0), Point(x: 10, y: -7), Point(x: 22, y: 4), Point(x: 30, y: 0)])
        let tombstone = try #require(pair.a.state.store.element(node, PathFields.point(contour, drawn[2].id)))
        #expect(tombstone.isDeleted, "the moved point stays deleted; its edit is retained on the tombstone")
    }

    // MARK: Names

    @Test func displayNamesAndNamedLabels() throws {
        var replica = Replica(1)
        let (node, _) = PathFixture.ids(try replica.perform(PathFixture.open([(0, 0), (10, 0)])), in: replica.state)
        #expect(replica.state.displayName(of: node) == "Path" && replica.state.name(of: node) == nil)
        #expect(replica.state.namedLabel("Move", for: [node]) == nil)
        _ = try replica.perform(SetNameOrNote([node], .name, "Logo mark"))
        #expect(replica.state.displayName(of: node) == "Logo mark")
        #expect(replica.state.namedLabel("Move", for: [node]) == "Move \"Logo mark\"")
        #expect(replica.state.namedLabel("Move", for: [node, node]) == nil)
        #expect(replica.state.displayName(of: OpID(counter: 999, replica: 9)) == "Object")
        let titles = [NodeKind.path, .rect, .ellipse, .polygon, .chart, .connector, .text, .group, .brush, .blend, .extrude, .layer, .symbol,
                      .instance, .placedFile, .barcode].map(\.title)
        #expect(Set(titles).count == titles.count)
    }

    @Test func appendNoteAddsALineAndStopsAtTheLimit() throws {
        var replica = Replica(1)
        let (node, _) = PathFixture.ids(try replica.perform(PathFixture.open([(0, 0), (10, 0)])), in: replica.state)
        let change = try #require(try replica.perform(AppendNote([node], line: "Copy from Priya's offline edits, 14 Mar 2026")))
        #expect(change.label == "Add note" && change.ops.count == 1)
        #expect(NodeValues.common(replica.state.props(node))?.note == "Copy from Priya's offline edits, 14 Mar 2026")
        _ = try replica.perform(AppendNote([node], line: "Traced from scan.png"))
        #expect(NodeValues.common(replica.state.props(node))?.note == "Copy from Priya's offline edits, 14 Mar 2026\nTraced from scan.png")
        #expect(AppendNote.appending("b", to: String(repeating: "a", count: 8_192)).count == 8_192)
        #expect(throws: ObjectEditError.self) { try replica.perform(AppendNote([node], line: "")) }
    }

    @Test func concurrentNameAndNoteEditsKeepBothAndNotesGoToTheGreaterOpID() throws {
        var pair = Pair()
        let (node, _) = PathFixture.ids(try pair.a.perform(PathFixture.open([(0, 0), (10, 0)])), in: pair.a.state)
        pair.sync()
        _ = try pair.a.perform(SetNameOrNote([node], .name, "Name from A"))
        _ = try pair.b.perform(SetNameOrNote([node], .note, "Note from B"))
        pair.sync()
        #expect(pair.a.state.name(of: node) == "Name from A" && NodeValues.common(pair.b.state.props(node))?.note == "Note from B")
        let a = try #require(try pair.a.perform(SetNameOrNote([node], .note, "A's note")))
        let b = try #require(try pair.b.perform(SetNameOrNote([node], .note, "B's note")))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let winner = OpID(counter: a.startCounter, replica: 0xA) > OpID(counter: b.startCounter, replica: 0xB) ? "A's note" : "B's note"
        #expect(NodeValues.common(pair.a.state.props(node))?.note == winner)
        #expect(pair.a.state.store.losingWrites(node, CommonFields.note(.path)).count >= 1, "the losing write is retained")
    }
}
