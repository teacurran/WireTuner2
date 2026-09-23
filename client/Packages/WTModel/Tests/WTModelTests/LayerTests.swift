import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

enum LayerFixture {
    /// A guides layer (created as a template would).
    static func guides(name: String = "Guides") -> OpsCommand {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.layer.common.name = name
        props.layer.role = .guides
        props.layer.visible = true
        return OpsCommand("Guides", ops: [Ops.create(parent: WellKnown.layers, position: [0x40], props: props)])
    }

    /// Creates layers named `names` bottom first on `replica`; returns their ids.
    static func layers(_ names: [String], on replica: inout Replica) throws -> [OpID] {
        var ids: [OpID] = []
        for name in names {
            let change = try replica.perform(CreateLayer(name: name, above: ids.last))
            ids.append(change!.createdNodes[0])
        }
        return ids
    }

    static func rect(on layer: OpID?, x: Double = 0, size: Double = 10) -> CreateShape {
        CreateShape(.rectangle(CornerRadii()), size: Size(width: size, height: size), transform: .translation(x: x, y: 0), layer: layer)
    }

    static func object(_ command: any Command, on replica: inout Replica) throws -> OpID {
        try replica.perform(command)!.createdObjects[0]
    }
}

@Suite struct LayerOrderTests {
    @Test func backgroundLayersStackBelowPrintingOnes() throws {
        var a = Replica(0xA)
        let ids = try LayerFixture.layers(["One", "Two", "Three"], on: &a)
        try a.perform(SetLayerFlag([ids[2]], .printing, false))
        let order = LayerOrder(a.state)
        #expect(order.layers.map(\.id) == [ids[2], ids[0], ids[1]])
        #expect(order.layers.first?.isBackground == true)
        #expect(order.defaultLayer == ids[0])
        #expect(order.printingLayers.map(\.id) == [ids[0], ids[1]])
        #expect(order.drawingLayer == ids[1])
        #expect(order.index(of: ids[1]) == 2)
        #expect(order.layer(ids[1])?.name == "Two")
        #expect(order.guides == nil)
    }

    @Test func guidesNormalizationAndFallbacks() throws {
        var a = Replica(0xA)
        let first = try a.perform(LayerFixture.guides())!.createdNodes[0]
        let second = try a.perform(LayerFixture.guides(name: "Extra"))!.createdNodes[0]
        try a.perform(DeleteLayerForTest(first))
        let order = LayerOrder(a.state)
        #expect(order.guides == first)
        #expect(order.isLive(first))
        #expect(order.layer(second)?.role == .ordinary)
        // Nothing prints: the smallest non-Guides layer reads as the default, live and printing.
        #expect(order.defaultLayer == second)
        #expect(order.layer(second)?.printing == true)
        // Drawing skips Guides.
        #expect(order.drawingLayer == second)
    }

    @Test func deletedLayersRouteTheirObjects() throws {
        var a = Replica(0xA)
        let ids = try LayerFixture.layers(["Base", "Sketch", "Top"], on: &a)
        let onSketch = try LayerFixture.object(LayerFixture.rect(on: ids[1]), on: &a)
        let onTop = try LayerFixture.object(LayerFixture.rect(on: ids[2]), on: &a)
        // Deleted without a merge: its objects show on the default layer.
        try a.perform(DeleteLayerForTest(ids[1]))
        var order = LayerOrder(a.state)
        #expect(order.displayLayer(for: ids[1]) == ids[0])
        #expect(order.objects(on: ids[0], in: a.state) == [onSketch])
        #expect(order.layer(of: onSketch, in: a.state) == ids[0])
        // Merged into a live layer: they show there.
        try a.perform(OpsCommand("merged", ops: [Ops.set(ids[1], [LayerFields.mergedInto], values: Layers.values { $0.mergedInto.id = ids[2].proto })]))
        order = LayerOrder(a.state)
        #expect(order.displayLayer(for: ids[1]) == ids[2])
        #expect(order.objects(on: ids[2], in: a.state) == [onTop, onSketch])
        #expect(order.layer(of: OpID(counter: 999, replica: 9), in: a.state) == nil)
        // The scene shows it on the target.
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(a.state)
        #expect(scene.object(onSketch)?.layer == ids[2])
        #expect(scene.layers?.defaultLayer == ids[0])
    }

    @Test func lockedAndHiddenLayersInTheScene() throws {
        var a = Replica(0xA)
        let ids = try LayerFixture.layers(["Base", "Top"], on: &a)
        let base = try LayerFixture.object(LayerFixture.rect(on: ids[0]), on: &a)
        let top = try LayerFixture.object(LayerFixture.rect(on: ids[1]), on: &a)
        try a.perform(SetLayerFlag([ids[0]], .locked, true))
        try a.perform(SetLayerFlag([ids[1]], .visible, false))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(a.state)
        #expect(scene.object(base)?.isEffectivelyLocked == true)
        #expect(scene.object(base)?.isLocked == false)
        #expect(scene.object(top) == nil)
        #expect(Objects.isEffectivelyLocked(base, in: a.state))
        #expect(!Objects.isEffectivelyLocked(top, in: a.state))
        // The drawing layer skips the locked and the hidden ones; a hidden active layer takes objects.
        #expect(LayerOrder(a.state).drawingLayer == nil)
        let created = try a.perform(LayerFixture.rect(on: ids[1]))!
        #expect(Objects.parent(of: created.createdObjects[0], in: a.state) == ids[1])
        // A locked preferred layer is not drawn on.
        let fallback = try a.perform(LayerFixture.rect(on: ids[0]))!
        #expect(fallback.createdNodes.count == 2)   // a Foreground layer and the rectangle
    }
}

/// Deletes a layer node alone (a remote delete, bypassing the command layer's checks).
struct DeleteLayerForTest: Command {
    let layer: OpID
    init(_ layer: OpID) { self.layer = layer }
    var label: String { "Delete layer" }
    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        builder.append(Ops.setDeleted(layer))
    }
}

@Suite struct LayerCommandTests {
    @Test func newLayerGoesAboveTheActiveOneAndPrintsLikeIt() throws {
        var a = Replica(0xA)
        let ids = try LayerFixture.layers(["One", "Two"], on: &a)
        try a.perform(SetLayerFlag([ids[0]], .printing, false))
        let change = try a.perform(CreateLayer(name: "Three", above: ids[0]))!
        #expect(change.label == "New Layer")
        let three = change.createdNodes[0]
        let order = LayerOrder(a.state)
        #expect(order.layers.map(\.id) == [ids[0], three, ids[1]])
        #expect(order.layer(three)?.printing == false)
        #expect(order.layer(three)?.visible == true)
        // Without an active layer it goes on top, printing.
        let top = try a.perform(CreateLayer(name: String(repeating: "x", count: 300)))!.createdNodes[0]
        #expect(LayerOrder(a.state).layers.last?.id == top)
        #expect(LayerOrder(a.state).layer(top)?.name.count == 256)
    }

    @Test func duplicateCopiesTheObjectsDeeply() throws {
        var a = Replica(0xA)
        let ids = try LayerFixture.layers(["Art"], on: &a)
        let path = try LayerFixture.object(PathFixture.closed([(0, 0), (10, 0), (10, 10)]), on: &a)
        let change = try a.perform(DuplicateLayer(ids[0]))!
        #expect(change.label == "Duplicate Layer")
        let copy = change.createdNodes[0]
        let order = LayerOrder(a.state)
        #expect(order.layer(copy)?.name == "Art copy")
        #expect(order.layers.map(\.id) == [ids[0], copy])
        let copied = a.state.liveChildren(copy)
        #expect(copied.count == 1)
        #expect(a.path(copied[0]).contours.map { $0.drawn.map(\.anchor) } == a.path(path).contours.map { $0.drawn.map(\.anchor) })
        // Editing the original does not reach the copy.
        let contour = a.path(path).contours[0]
        try a.perform(MovePoints(node: path, contour: contour.id, point: contour.points[0].id, to: Point(x: 5, y: 5)))
        #expect(a.path(copied[0]).contours[0].points[0].anchor == Point(x: 0, y: 0))
        #expect(throws: LayerError.notALayer(path)) { try a.perform(DuplicateLayer(path)) }
    }

    @Test func renameRefusesGuides() throws {
        var a = Replica(0xA)
        let guides = try a.perform(LayerFixture.guides())!.createdNodes[0]
        let ids = try LayerFixture.layers(["One"], on: &a)
        let change = try a.perform(RenameLayer(ids[0], to: "Renamed"))!
        #expect(change.label == "Rename Layer")
        #expect(LayerOrder(a.state).layer(ids[0])?.name == "Renamed")
        #expect(throws: LayerError.guidesLayer) { try a.perform(RenameLayer(guides, to: "No")) }
        #expect(throws: LayerError.guidesLayer) { try a.perform(RemoveLayers([guides])) }
        #expect(throws: LayerError.guidesLayer) { try a.perform(MergeLayers([ids[0], guides])) }
    }

    @Test func removeDeletesObjectsThenTheLayerInOneUndoableChange() throws {
        var a = Replica(0xA)
        let ids = try LayerFixture.layers(["Base", "Sketch"], on: &a)
        let object = try LayerFixture.object(LayerFixture.rect(on: ids[1]), on: &a)
        let command = RemoveLayers.named([ids[1]], in: a.state)
        #expect(command.label == "Remove layer Sketch")
        #expect(RemoveLayers([ids[0], ids[1]]).label == "Remove 2 layers")
        #expect(RemoveLayers([ids[0]]).label == "Remove layer")
        let change = try a.perform(command)!
        #expect(change.ops.count == 2)
        #expect(!a.state.isLive(object) && !a.state.isLive(ids[1]))
        // The last printing layer stays.
        #expect(throws: LayerError.lastPrintingLayer) { try a.perform(RemoveLayers([ids[0]])) }
        a.undo()
        #expect(a.state.isLive(object) && a.state.isLive(ids[1]))
    }

    @Test func reorderMovesAndCrossesTheSeparator() throws {
        var a = Replica(0xA)
        let ids = try LayerFixture.layers(["One", "Two", "Three"], on: &a)
        let change = try a.perform(ReorderLayer(ids[2], to: 0))!
        #expect(change.label == "Move Layer" && change.ops.count == 1)
        #expect(LayerOrder(a.state).layers.map(\.id) == [ids[2], ids[0], ids[1]])
        // Below the separator: printing off as well.
        let crossing = try a.perform(ReorderLayer(ids[1], to: 0, printing: false))!
        #expect(crossing.ops.count == 2)
        #expect(LayerOrder(a.state).layers.map(\.id) == [ids[1], ids[2], ids[0]])
        #expect(LayerOrder(a.state).layer(ids[1])?.printing == false)
        // Dropped among background layers it takes their printing.
        try a.perform(ReorderLayer(ids[2], to: 1))
        #expect(LayerOrder(a.state).layer(ids[2])?.printing == false)
        #expect(throws: LayerError.lastPrintingLayer) { try a.perform(ReorderLayer(ids[0], to: 0, printing: false)) }
        // To the top again.
        try a.perform(ReorderLayer(ids[1], to: 9, printing: true))
        #expect(LayerOrder(a.state).layers.last?.id == ids[1])
        #expect(throws: LayerError.notALayer(OpID(counter: 99, replica: 9))) { try a.perform(ReorderLayer(OpID(counter: 99, replica: 9), to: 0)) }
    }

    @Test func flagsAndHighlight() throws {
        var a = Replica(0xA)
        let ids = try LayerFixture.layers(["One", "Two", "Three", "Four"], on: &a)
        #expect(try a.perform(SetLayerFlag(ids, .visible, false))?.label == "Hide 4 layers")
        #expect(SetLayerFlag([ids[0]], .visible, true).label == "Show layer")
        #expect(SetLayerFlag([ids[0]], .locked, true).label == "Lock layer")
        #expect(SetLayerFlag([ids[0]], .locked, false).label == "Unlock layer")
        #expect(SetLayerFlag([ids[0]], .printing, true).label == "Print layer")
        #expect(SetLayerFlag([ids[0]], .printing, false).label == "Don't print layer")
        #expect(SetLayerFlag([ids[0]], .keyline, true).label == "Keyline layer")
        #expect(SetLayerFlag([ids[0]], .keyline, false).label == "Preview layer")
        try a.perform(SetLayerFlag([ids[0]], .keyline, true))
        try a.perform(SetLayerFlag([ids[1]], .locked, true))
        let order = LayerOrder(a.state)
        #expect(order.layers.allSatisfy { !$0.visible })
        #expect(order.layer(ids[0])?.keyline == true && order.layer(ids[1])?.locked == true)
        #expect(throws: LayerError.lastPrintingLayer) { try a.perform(SetLayerFlag(ids, .printing, false)) }
        var red = Wiretuner_Doc_V1_Color()
        red.rgb.r = 1
        #expect(try a.perform(SetLayerHighlight(ids[0], color: red))?.label == "Change Highlight Color")
        #expect(LayerOrder(a.state).layer(ids[0])?.highlight == red)
    }

    @Test func mergeKeepsStackingOntoTheLowestLayer() throws {
        var a = Replica(0xA)
        let ids = try LayerFixture.layers(["Base", "Middle", "Top"], on: &a)
        let base = try LayerFixture.object(LayerFixture.rect(on: ids[0]), on: &a)
        let middle1 = try LayerFixture.object(LayerFixture.rect(on: ids[1]), on: &a)
        let middle2 = try LayerFixture.object(LayerFixture.rect(on: ids[1]), on: &a)
        let top = try LayerFixture.object(LayerFixture.rect(on: ids[2]), on: &a)
        let change = try a.perform(MergeLayers([ids[2], ids[0], ids[1]]))!
        #expect(change.label == "Merge 3 layers")
        #expect(a.state.liveChildren(ids[0]) == [base, middle1, middle2, top])
        #expect(!a.state.isLive(ids[1]) && !a.state.isLive(ids[2]))
        #expect(LayerOrder(a.state).layer(ids[1])?.mergedInto == ids[0])
        a.undo()
        #expect(a.state.liveChildren(ids[1]) == [middle1, middle2])
        // One layer merges nothing.
        #expect(try a.perform(MergeLayers([ids[0]])) == nil)
        // Foreground: every printing layer.
        try a.perform(SetLayerFlag([ids[0]], .printing, false))
        let foreground = MergeLayers.foreground(in: a.state)
        #expect(foreground.layers == [ids[1], ids[2]])
        try a.perform(foreground)
        #expect(a.state.liveChildren(ids[1]) == [middle1, middle2, top])
    }

    @Test func moveObjectsArriveOnTopInOrder() throws {
        var a = Replica(0xA)
        let ids = try LayerFixture.layers(["Base", "Top"], on: &a)
        let first = try LayerFixture.object(LayerFixture.rect(on: ids[0]), on: &a)
        let second = try LayerFixture.object(LayerFixture.rect(on: ids[0]), on: &a)
        let existing = try LayerFixture.object(LayerFixture.rect(on: ids[1]), on: &a)
        let change = try a.perform(MoveObjectsToLayer([second, first], to: ids[1]))!
        #expect(change.label == "Move 2 objects to layer")
        #expect(MoveObjectsToLayer([first], to: ids[1]).label == "Move to Layer")
        #expect(a.state.liveChildren(ids[1]) == [existing, first, second])
        try a.perform(SetLayerFlag([ids[0]], .locked, true))
        #expect(throws: LayerError.lockedLayer(ids[0])) { try a.perform(MoveObjectsToLayer([first], to: ids[0])) }
    }
}

/// The merge tests of LIB-002 and LIB-003, through two in-process replicas.
@Suite struct LayerMergeTests {
    struct Shared {
        var pair = Pair()
        var layers: [OpID] = []

        init(_ names: [String]) throws {
            layers = try LayerFixture.layers(names, on: &pair.a)
            pair.sync()
        }

        func converged() {
            #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        }
    }

    @Test func concurrentRenamesAreLastWriterWinsWithTheLoserRetained() throws {
        var s = try Shared(["Sketch"])
        let a = try s.pair.a.perform(RenameLayer(s.layers[0], to: "Mine"))!
        let b = try s.pair.b.perform(RenameLayer(s.layers[0], to: "Theirs"))!
        s.pair.sync()
        s.converged()
        let winner = OpID(counter: a.startCounter, replica: a.replica) > OpID(counter: b.startCounter, replica: b.replica) ? "Mine" : "Theirs"
        #expect(LayerOrder(s.pair.a.state).layer(s.layers[0])?.name == winner)
        #expect(s.pair.a.state.store.losingWrites(s.layers[0], LayerFields.name).count == 2)   // the creation and the loser
    }

    @Test func concurrentTogglesOfDifferentFlagsKeepBoth() throws {
        var s = try Shared(["One", "Two"])
        try s.pair.a.perform(SetLayerFlag([s.layers[0]], .visible, false))
        try s.pair.b.perform(SetLayerFlag([s.layers[0]], .locked, true))
        s.pair.sync()
        s.converged()
        let layer = LayerOrder(s.pair.b.state).layer(s.layers[0])!
        #expect(!layer.visible && layer.locked)
    }

    @Test func removeVersusCreateOnTheLayerKeepsTheObjectOnTheDefaultLayer() throws {
        var s = try Shared(["Base", "Sketch"])
        try s.pair.a.perform(RemoveLayers([s.layers[1]]))
        let object = try LayerFixture.object(LayerFixture.rect(on: s.layers[1]), on: &s.pair.b)
        s.pair.sync()
        s.converged()
        #expect(s.pair.a.state.isLive(object))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(s.pair.a.state)
        #expect(scene.object(object)?.layer == s.layers[0])
    }

    @Test func mergeVersusAddToASourceRoutesTheObjectToTheTarget() throws {
        var s = try Shared(["Base", "Sketch"])
        try s.pair.a.perform(MergeLayers([s.layers[0], s.layers[1]]))
        let object = try LayerFixture.object(LayerFixture.rect(on: s.layers[1]), on: &s.pair.b)
        s.pair.sync()
        s.converged()
        let order = LayerOrder(s.pair.a.state)
        #expect(order.objects(on: s.layers[0], in: s.pair.a.state).contains(object))
    }

    @Test func overlappingMergesOntoDifferentTargetsLoseNothing() throws {
        var s = try Shared(["One", "Two", "Three"])
        var objects: [OpID] = []
        for layer in s.layers { objects.append(try LayerFixture.object(LayerFixture.rect(on: layer), on: &s.pair.a)) }
        s.pair.sync()
        try s.pair.a.perform(MergeLayers([s.layers[0], s.layers[1]]))
        try s.pair.b.perform(MergeLayers([s.layers[1], s.layers[2]]))
        s.pair.sync()
        s.converged()
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(s.pair.a.state)
        for object in objects {
            #expect(scene.object(object) != nil)
        }
        #expect(!s.pair.a.state.isLive(s.layers[1]))
    }

    @Test func moveVersusMoveOfOneObjectConvergesOnOneLayer() throws {
        var s = try Shared(["One", "Two", "Three"])
        let object = try LayerFixture.object(LayerFixture.rect(on: s.layers[0]), on: &s.pair.a)
        s.pair.sync()
        try s.pair.a.perform(MoveObjectsToLayer([object], to: s.layers[1]))
        try s.pair.b.perform(MoveObjectsToLayer([object], to: s.layers[2]))
        s.pair.sync()
        s.converged()
        let parent = Objects.parent(of: object, in: s.pair.a.state)
        #expect(parent == s.layers[1] || parent == s.layers[2])
    }

    @Test func everyPrintingLayerDeletedConcurrentlyFallsBackToTheSmallestLayer() throws {
        var s = try Shared(["One", "Two"])
        try s.pair.a.perform(RemoveLayers([s.layers[0]]))
        try s.pair.b.perform(RemoveLayers([s.layers[1]]))
        s.pair.sync()
        s.converged()
        let order = LayerOrder(s.pair.a.state)
        #expect(order.defaultLayer == s.layers.min())
        #expect(order.layer(s.layers.min()!)?.printing == true)
        #expect(order.isLive(s.layers.min()!))
    }
}
