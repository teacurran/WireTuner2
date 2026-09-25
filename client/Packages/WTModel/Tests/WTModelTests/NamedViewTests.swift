import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Named views (BASIC-015, document-view.adoc "Named views").
@Suite struct NamedViewTests {
    static let logo = NamedViewTarget(magnification: 4, scrollOrigin: Point(x: 100, y: 200), mode: .keyline)
    static let whole = NamedViewTarget(magnification: 0.5, scrollOrigin: Point(x: -10, y: -10))

    static func create(_ name: String, _ target: NamedViewTarget = logo, on replica: inout Replica) throws -> OpID {
        try replica.perform(CreateCustomView(name: name, target: target))!.createdNodes[0]
    }

    @Test func eachCommandIsOneLabelledChangeWithAnInverse() throws {
        var a = Replica(0xA)
        let change = try #require(try a.perform(CreateCustomView(name: "Logo detail", target: Self.logo)))
        #expect(change.label == "New View" && change.ops.count == 1)
        let view = change.createdNodes[0]
        let second = try Self.create("", Self.whole, on: &a)
        var views = NamedViews.list(a.state)
        #expect(views.map(\.name) == ["Logo detail", "View 2"])
        #expect(views[0].target == Self.logo && views[1].target.mode == .preview)
        #expect(try a.perform(RedefineCustomView(view, target: Self.whole))?.label == "Redefine View")
        #expect(NamedViews.view(view, in: a.state)?.target == Self.whole)
        #expect(try a.perform(RenameCustomView(view, to: "Mark"))?.label == "Rename View")
        #expect(try a.perform(RenameCustomView(view, to: "Mark")) == nil, "no change for the same name")
        #expect(try a.perform(MoveCustomView(view, to: 5))?.label == "Reorder Views")
        views = NamedViews.list(a.state)
        #expect(views.map(\.id) == [second, view] && views.map(\.name) == ["View 1", "Mark"])
        #expect(try a.perform(MoveCustomView(view, to: 1)) == nil, "already there")
        #expect(try a.perform(DeleteCustomView([view, view]))?.label == "Delete View")
        #expect(NamedViews.list(a.state).map(\.id) == [second])
        #expect(try a.perform(DeleteCustomView([view])) == nil)
        // Undo walks back through every step.
        a.undo()
        #expect(NamedViews.list(a.state).count == 2)
        a.undo()
        #expect(NamedViews.list(a.state).map(\.id) == [view, second])
        a.undo()
        #expect(NamedViews.view(view, in: a.state)?.storedName == "Logo detail")
        a.undo()
        #expect(NamedViews.view(view, in: a.state)?.target == Self.logo)
        #expect(throws: NamedViewError.notAView(OpID(counter: 99, replica: 9))) {
            try a.perform(RedefineCustomView(OpID(counter: 99, replica: 9), target: Self.logo))
        }
        #expect(throws: NamedViewError.self) { try a.perform(RenameCustomView(WellKnown.layers, to: "x")) }
        #expect(throws: NamedViewError.self) { try a.perform(MoveCustomView(WellKnown.layers, to: 0)) }
    }

    @Test func readTimeRulesClampAndIgnoreStrayViews() throws {
        var a = Replica(0xA)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.customView.target.magnification = 900
        props.customView.target.scrollOrigin.x = .nan
        let wild = try a.perform(OpsCommand("wild", ops: [Ops.create(parent: WellKnown.settings, position: [0x80], props: props)]))!.createdNodes[0]
        props.customView.target.magnification = 0
        _ = try a.perform(OpsCommand("unset", ops: [Ops.create(parent: WellKnown.settings, position: [0x90], props: props)]))
        _ = try a.perform(OpsCommand("stray", ops: [Ops.create(parent: WellKnown.layers, position: [0x80], props: props)]))
        let views = NamedViews.list(a.state)
        #expect(views.count == 2, "a view under another parent is ignored")
        #expect(views[0].id == wild && views[0].target.magnification == 256 && views[0].target.scrollOrigin.x == 0)
        #expect(views[1].target.magnification == 1)
        #expect(NamedViewTarget(magnification: .infinity, scrollOrigin: .zero).proto.magnification == 1)
        #expect(NamedViewTarget(magnification: 0.001, scrollOrigin: .zero).proto.magnification == 0.06)
    }

    @Test func zoomToolShiftDragFitsTheArea() {
        let target = NamedViews.target(fitting: Rect(x: 100, y: 100, width: 200, height: 100), viewSize: Size(width: 800, height: 600), mode: .preview)
        #expect(target.magnification == 4)
        #expect(target.scrollOrigin == Point(x: 100, y: 75))
        let tiny = NamedViews.target(fitting: Rect(x: 0, y: 0, width: 0, height: 0), viewSize: Size(width: 800, height: 600), mode: .keyline)
        #expect(tiny.magnification == 256 && tiny.mode == .keyline)
    }

    @Test func previousSwapsTheLastTwoRecalledViews() throws {
        var a = Replica(0xA)
        let one = try Self.create("One", on: &a)
        let two = try Self.create("Two", Self.whole, on: &a)
        var recall = NamedViewRecall()
        #expect(!recall.canGoBack(in: a.state) && recall.previous(in: a.state) == nil)
        recall.recalled(one)
        recall.recalled(one)
        #expect(!recall.canGoBack(in: a.state), "fewer than two")
        recall.recalled(two)
        let back = try #require(recall.previous(in: a.state))
        #expect(back.view.id == one && back.recall == NamedViewRecall(latest: one, before: two))
        #expect(back.recall.previous(in: a.state)?.view.id == two)
        // The pair round-trips through ViewState.
        var state = Wiretuner_Doc_V1_ViewState()
        back.recall.store(into: &state)
        #expect(NamedViewRecall(state) == back.recall)
        NamedViewRecall().store(into: &state)
        #expect(NamedViewRecall(state) == NamedViewRecall())
        // A deleted view drops out of the pair.
        try a.perform(DeleteCustomView([one]))
        #expect(!recall.canGoBack(in: a.state))
        #expect(recall.live(in: a.state) == NamedViewRecall(latest: two))
    }

    // MARK: Merge

    static func pair() throws -> (Pair, OpID) {
        var pair = Pair()
        let view = try create("Logo", on: &pair.a)
        pair.sync()
        return (pair, view)
    }

    @Test func redefineVersusRenameKeepsBoth() throws {
        var (pair, view) = try Self.pair()
        try pair.a.perform(RedefineCustomView(view, target: Self.whole))
        try pair.b.perform(RenameCustomView(view, to: "Badge"))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        for replica in [pair.a, pair.b] {
            let merged = try #require(NamedViews.view(view, in: replica.state))
            #expect(merged.name == "Badge" && merged.target == Self.whole)
        }
    }

    @Test func redefineVersusRedefineIsLastWriterWinsWhole() throws {
        var (pair, view) = try Self.pair()
        try pair.a.perform(RedefineCustomView(view, target: Self.whole))
        try pair.b.perform(RedefineCustomView(view, target: NamedViewTarget(magnification: 2, scrollOrigin: Point(x: 5, y: 5))))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        let merged = try #require(NamedViews.view(view, in: pair.a.state))
        #expect(merged.target == NamedViewTarget(magnification: 2, scrollOrigin: Point(x: 5, y: 5)), "B's greater id wins, zoom and scroll together")
        #expect(!pair.a.state.losingWrites(view, NamedViews.target).isEmpty, "the loser is retained")
    }

    @Test func deleteVersusRedefineShowsTheViewGoneAndKeepsTheEditForRestore() throws {
        var (pair, view) = try Self.pair()
        try pair.a.perform(DeleteCustomView([view]))
        try pair.b.perform(RedefineCustomView(view, target: Self.whole))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        #expect(NamedViews.list(pair.b.state).isEmpty, "B's next look shows the view gone")
        // Restore (the review's edit-vs-delete row) brings it back with B's target.
        try pair.b.perform(OpsCommand("Restore", ops: [Ops.setDeleted(view, false)]))
        #expect(NamedViews.view(view, in: pair.b.state)?.target == Self.whole)
    }

    @Test func undoOfARedefineSkipsWhenSomeoneElseRedefinedSince() throws {
        var (pair, view) = try Self.pair()
        try pair.a.perform(RedefineCustomView(view, target: Self.whole))
        pair.sync()
        let theirs = NamedViewTarget(magnification: 8, scrollOrigin: Point(x: 1, y: 1))
        try pair.b.perform(RedefineCustomView(view, target: theirs))
        pair.sync()
        pair.a.undo()
        pair.sync()
        #expect(NamedViews.view(view, in: pair.a.state)?.target == theirs, "B's redefine stands")
        // Without an intervening edit, undo restores the previous target.
        try pair.a.perform(RedefineCustomView(view, target: Self.whole))
        pair.a.undo()
        #expect(NamedViews.view(view, in: pair.a.state)?.target == theirs)
    }

    @Test func concurrentCreatesWithOneNameMakeTwoViews() throws {
        var pair = Pair()
        _ = try Self.create("Detail", on: &pair.a)
        _ = try Self.create("Detail", Self.whole, on: &pair.b)
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        #expect(NamedViews.list(pair.a.state).map(\.name) == ["Detail", "Detail"])
    }
}
