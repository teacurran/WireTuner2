import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// The Select menu's scoping (OBJ-006), Clear, and objects hidden on this Mac (OBJ-007).
@Suite struct SelectCommandTests {
    /// Two layers; on the bottom one a rectangle on the page, one off it, a locked one, and a group
    /// of two (one member locked); on the top layer, locked, one more rectangle.
    struct World {
        var replica = Replica(0xA)
        var layers: [OpID] = []
        var onPage = OpID.zero, offPage = OpID.zero, locked = OpID.zero, group = OpID.zero
        var member = OpID.zero, lockedMember = OpID.zero, onLockedLayer = OpID.zero
        static let page = Rect(x: 0, y: 0, width: 50, height: 50)

        init() throws {
            layers = try LayerFixture.layers(["Bottom", "Top"], on: &replica)
            onPage = try LayerFixture.object(LayerFixture.rect(on: layers[0], x: 0), on: &replica)
            offPage = try LayerFixture.object(LayerFixture.rect(on: layers[0], x: 100), on: &replica)
            locked = try LayerFixture.object(LayerFixture.rect(on: layers[0], x: 20), on: &replica)
            member = try LayerFixture.object(LayerFixture.rect(on: layers[0], x: 30), on: &replica)
            lockedMember = try LayerFixture.object(LayerFixture.rect(on: layers[0], x: 40), on: &replica)
            group = try replica.perform(GroupObjects([member, lockedMember]))!.createdObjects[0]
            try replica.perform(SetLocked([locked, lockedMember], locked: true))
            onLockedLayer = try LayerFixture.object(LayerFixture.rect(on: layers[1], x: 10), on: &replica)
            try replica.perform(SetLayerFlag([layers[1]], .locked, true))
        }

        func scene(hiding hidden: Set<OpID> = []) -> DocumentScene {
            var builder = DocumentDisplayListBuilder(canvas: "select")
            builder.locallyHidden = hidden
            return builder.rebuild(replica.state)
        }
    }

    @Test func allSkipsLockedObjectsAndLockedLayersAndKeepsToThePage() throws {
        let world = try World()
        let scene = world.scene()
        #expect(SelectScope.all(in: scene, page: World.page) == [world.onPage, world.group])
        #expect(SelectScope.all(in: scene) == [world.onPage, world.offPage, world.group], "All in Document includes the pasteboard")
        #expect(SelectScope.inverted([world.onPage], in: scene, page: World.page) == [world.group])
        #expect(SelectScope.inverted([], in: scene, page: nil) == [world.onPage, world.offPage, world.group])
    }

    @Test func hiddenLayersAndLocallyHiddenObjectsAreNotSelected() throws {
        var world = try World()
        try world.replica.perform(SetLayerFlag([world.layers[1]], .locked, false))
        try world.replica.perform(SetLayerFlag([world.layers[1]], .visible, false))
        #expect(!SelectScope.all(in: world.scene()).contains(world.onLockedLayer))
        let hidden = world.scene(hiding: [world.onPage, world.member])
        #expect(SelectScope.all(in: hidden) == [world.offPage, world.group])
        #expect(hidden.object(world.onPage) == nil && hidden.object(world.member) == nil)
        #expect(SelectScope.members(of: world.group, in: hidden) == [world.lockedMember])
    }

    @Test func superselectClimbsOneLevelAndStopsAtTheTop() throws {
        let world = try World()
        let scene = world.scene()
        #expect(SelectScope.superselect([world.member], in: scene) == [world.group])
        #expect(SelectScope.superselect([world.member, world.lockedMember, world.onPage], in: scene) == [world.group, world.onPage])
        #expect(SelectScope.superselect([world.group], in: scene) == nil, "disabled at the top")
        #expect(SelectScope.superselect([], in: scene) == nil)
    }

    @Test func subselectAllSelectsTheUnlockedMembers() throws {
        let world = try World()
        let scene = world.scene()
        #expect(SelectScope.members(of: world.group, in: scene) == [world.member, world.lockedMember])
        #expect(SelectScope.subselectAll([world.group], in: scene) == [world.member])
        #expect(SelectScope.subselectAll([world.onPage], in: scene).isEmpty)
    }

    @Test func clearIsOneChangeNamedByItsCountAndSkipsLockedObjects() throws {
        var world = try World()
        #expect(ClearObjects([world.onPage]).label == "Delete 1 object")
        let change = try #require(try world.replica.perform(ClearObjects([world.onPage, world.offPage, world.locked])))
        #expect(change.label == "Delete 3 objects")
        #expect(change.ops.count == 2)
        #expect(!world.replica.state.isLive(world.onPage) && !world.replica.state.isLive(world.offPage) && world.replica.state.isLive(world.locked))
    }

    @Test func clearVersusRemoteEditLeavesTheNodeDeletedWithTheEditRetained() throws {
        var pair = Pair()
        let path = try LayerFixture.object(PathFixture.open([(0, 0), (10, 0)]), on: &pair.a)
        pair.sync()
        try pair.a.perform(ClearObjects([path]))
        let contour = pair.b.path(path).contours[0]
        try pair.b.perform(MovePoints(node: path, contour: contour.id, point: contour.points[0].id, to: Point(x: 7, y: 7)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(!pair.a.state.isLive(path) && !pair.b.state.isLive(path))
        #expect(pair.a.path(path).contours[0].points[0].anchor == Point(x: 7, y: 7))
    }

    @Test func locallyHiddenObjectsLeaveTheScreenButNotTheOutput() throws {
        let world = try World()
        var builder = DocumentDisplayListBuilder(canvas: "hide")
        let before = builder.rebuild(world.replica.state)
        builder.locallyHidden = [world.onPage]
        let (hidden, summary) = builder.invalidate([world.onPage], state: world.replica.state)
        #expect(hidden.object(world.onPage) == nil && before.object(world.onPage) != nil)
        #expect(summary.touchedNodes.contains(NodeID(world.onPage)))
        let output = builder.outputDisplayList(world.replica.state)
        #expect(output.nodeIDs.contains(NodeID(world.onPage)), "print and export still draw it")
        #expect(builder.locallyHidden == [world.onPage])
        builder.locallyHidden = []
        let (shown, _) = builder.invalidate([world.onPage], state: world.replica.state)
        #expect(shown.object(world.onPage) != nil)
    }
}
