import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto

/// The Layers panel's object tree and its drag command (layers.adoc, "Objects in the Layers
/// panel"; D-092).
@Suite struct ObjectTreeTests {
    /// Two layers (Art below Top); on Art, bottom first: a rectangle, a group of two rectangles
    /// translated by (100, 0), and a text block.
    struct Fixture {
        var replica = Replica(0xA)
        let art: OpID, top: OpID
        let rect: OpID, group: OpID, members: [OpID], text: OpID

        init() throws {
            let layers = try LayerFixture.layers(["Art", "Top"], on: &replica)
            art = layers[0]
            top = layers[1]
            rect = try LayerFixture.object(LayerFixture.rect(on: art), on: &replica)
            let a = try LayerFixture.object(LayerFixture.rect(on: art, x: 20), on: &replica)
            let b = try LayerFixture.object(LayerFixture.rect(on: art, x: 40), on: &replica)
            group = try replica.perform(GroupObjects([a, b], layer: art))!.createdNodes[0]
            try replica.perform(MoveObjects([group], by: Vector(dx: 100, dy: 0)))
            members = [a, b]
            text = try replica.perform(CreateTextBlock(.area(Rect(x: 0, y: 0, width: 200, height: 40)),
                                                       text: "Hello there, this is a rather long first line of text\nSecond", layer: art))!.createdObjects[0]
        }

        var tree: ObjectTree { ObjectTree(replica.state) }
    }

    @Test func layersListTheirObjectsAndGroupsTheirMembersFrontmostFirst() throws {
        let f = try Fixture()
        let tree = f.tree
        #expect(tree.children(of: f.art) == [f.text, f.group, f.rect])
        #expect(tree.children(of: f.group) == f.members.reversed())
        #expect(tree.children(of: f.top).isEmpty && !tree.hasChildren(f.top))
        #expect(tree.hasChildren(f.art) && tree.hasChildren(f.group) && !tree.hasChildren(f.rect))
        #expect(tree.children(of: f.rect).isEmpty)
        #expect(tree.parent(of: f.members[0]) == f.group && tree.parent(of: f.group) == f.art)
        #expect(tree.ancestors(of: f.members[1]) == [f.art, f.group])
        #expect(tree.ancestors(of: f.rect) == [f.art])
        #expect(tree.ancestors(of: f.art) == nil, "a layer is not an object")
        #expect(tree.isWithin(f.members[0], f.art) && !tree.isWithin(f.rect, f.group))
    }

    @Test func edgesOfTheTree() throws {
        var f = try Fixture()
        #expect(f.tree.parent(of: OpID(counter: 999, replica: 9)) == nil)
        // A blend's key objects are its structure: listed, not dragged; nothing drops into a blend.
        let blend = try #require(f.replica.perform(Blend(f.members))?.createdNodes.first)
        let keys = f.tree.children(of: blend)
        #expect(keys.count == 2 && keys.allSatisfy { !f.tree.isMovable($0) } && !f.tree.accepts(blend))
        #expect(f.tree.label(of: blend) == "Blend")
        #expect(!f.tree.isMovable(OpID(counter: 999, replica: 9)))
        // An instance whose symbol is gone reads as an instance; one of an unnamed symbol likewise.
        let path = try f.replica.perform(PathFixture.closed([(0, 0), (5, 0), (5, 5)]))!.createdObjects[0]
        let instance = try f.replica.perform(ConvertToSymbol([path]))!.createdObjects.last!
        let symbol = try #require(Symbols.symbol(of: instance, in: f.replica.state))
        var unnamed = Wiretuner_Doc_V1_NodeProps()
        unnamed.symbol.common.name = ""
        try f.replica.perform(OpsCommand("Unname", ops: [Ops.set(symbol, [CommonFields.name(.symbol)], values: unnamed)]))
        #expect(f.tree.label(of: instance) == "Symbol Instance")
        let short = try f.replica.perform(CreateTextBlock(.point(Point(x: 0, y: 0)), text: "  Short  ", layer: f.top))!.createdObjects[0]
        #expect(f.tree.label(of: short) == "Short")
        try f.replica.perform(OpsCommand("Cut symbol", ops: [Ops.setDeleted(symbol)]))
        #expect(f.tree.label(of: instance) == "Symbol Instance")
        // A member of a deleted group is not in the tree.
        try f.replica.perform(OpsCommand("Delete group", ops: [Ops.setDeleted(f.group)]))
        #expect(f.tree.ancestors(of: f.members[0]) == nil)
    }

    @Test func aGroupWithNoLiveMembersHasNoRow() throws {
        var f = try Fixture()
        try f.replica.perform(DeleteNodes(f.members))
        #expect(f.tree.children(of: f.art) == [f.text, f.rect])
        #expect(!f.tree.hasChildren(f.group))
    }

    @Test func labelsAreNamesElseTheKindRefined() throws {
        var f = try Fixture()
        #expect(f.tree.label(of: f.rect) == "Rectangle" && f.tree.name(of: f.rect) == nil)
        #expect(f.tree.label(of: f.group) == "Group")
        #expect(f.tree.label(of: f.text) == "Hello there, this is a rather long first…")
        try f.replica.perform(SetNameOrNote([f.rect], .name, "Logo mark"))
        #expect(f.tree.name(of: f.rect) == "Logo mark" && f.tree.label(of: f.rect) == "Logo mark")
        #expect(f.tree.name(of: f.rect) == f.replica.state.name(of: f.rect), "the one-register read agrees with the props")
        try f.replica.perform(SetLocked([f.rect], locked: true))
        #expect(f.tree.isLocked(f.rect) && !f.tree.isLocked(f.group))
        // A compound path, an empty text block, a symbol instance.
        let compound = try f.replica.perform(CreatePath(contours: [
            NewContour(closed: true, points: PathFixture.points([(0, 0), (10, 0), (10, 10)])),
            NewContour(closed: true, points: PathFixture.points([(2, 2), (4, 2), (4, 4)])),
        ], layer: f.top))!.createdObjects[0]
        #expect(f.tree.label(of: compound) == "Compound Path")
        let path = try f.replica.perform(PathFixture.closed([(0, 0), (5, 0), (5, 5)]))!.createdObjects[0]
        #expect(f.tree.label(of: path) == "Path")
        let empty = try f.replica.perform(CreateTextBlock(.point(Point(x: 0, y: 0)), layer: f.top))!.createdObjects[0]
        #expect(f.tree.label(of: empty) == "Text")
        let instance = try f.replica.perform(ConvertToSymbol([path], name: "Badge"))!.createdObjects.last!
        #expect(f.tree.label(of: instance) == "Badge")
        #expect(!f.tree.hasChildren(instance), "an instance's artwork is its symbol's")
        #expect(ObjectTree(EngineState()).defaultLabel(of: OpID(counter: 99, replica: 9)) == "Object")
    }

    /// A clip group on Top: the clip path (a rectangle) and one content rectangle above it.
    func clipGroup(_ f: inout Fixture) throws -> (group: OpID, clip: OpID, content: OpID) {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.group.kind = .clip
        let group = try f.replica.perform(OpsCommand("Clip", ops: [Ops.create(parent: f.top, position: [0x80], props: props)]))!.createdNodes[0]
        let clip = try LayerFixture.object(LayerFixture.rect(on: f.top, size: 50), on: &f.replica)
        let content = try LayerFixture.object(LayerFixture.rect(on: f.top, x: 5), on: &f.replica)
        try f.replica.perform(RestackObjects([clip, content], into: group, at: 0))
        var values = Wiretuner_Doc_V1_NodeProps()
        values.group.clipPath.id = clip.proto
        try f.replica.perform(OpsCommand("Set clip", ops: [Ops.set(group, [RegisterPath([NodeKind.group.rawValue, 4])], values: values)]))
        return (group, clip, content)
    }

    @Test func clipGroupsListTheClipPathLastAndKeepItThere() throws {
        var f = try Fixture()
        let (group, clip, content) = try clipGroup(&f)
        let tree = f.tree
        #expect(tree.children(of: group) == [content, clip])
        #expect(tree.role(of: clip) == .clipPath && tree.role(of: content) == .object)
        #expect(tree.label(of: group) == "Clip Group" && tree.label(of: clip) == "Clip Path")
        #expect(!tree.isMovable(clip) && tree.isMovable(content))
        // Dropping below the clip path lands just above it.
        try f.replica.perform(RestackObjects([f.rect], into: group, at: 2))
        #expect(f.tree.children(of: group) == [content, f.rect, clip])
        // The clip path itself does not move.
        try f.replica.perform(RestackObjects([clip], into: f.art, at: 0))
        #expect(f.tree.children(of: group).last == clip)
    }

    @Test func draggingReordersWithinALayerAsOneChange() throws {
        var f = try Fixture()
        // The rectangle (bottom) to the top of Art.
        let change = try f.replica.perform(RestackObjects([f.rect], into: f.art, at: 0))
        #expect(change?.ops.count == 1, "a move within one parent writes no transform")
        #expect(f.tree.children(of: f.art) == [f.rect, f.text, f.group])
        // Between the text and the group.
        try f.replica.perform(RestackObjects([f.rect], into: f.art, at: 2))
        #expect(f.tree.children(of: f.art) == [f.text, f.rect, f.group])
        // To the bottom, past the end.
        try f.replica.perform(RestackObjects([f.rect], into: f.art, at: 99))
        #expect(f.tree.children(of: f.art) == [f.text, f.group, f.rect])
        // Two objects keep their order.
        try f.replica.perform(RestackObjects([f.text, f.rect], into: f.top, at: 0))
        #expect(f.tree.children(of: f.top) == [f.text, f.rect])
        #expect(RestackObjects([f.rect], into: f.top, at: 0).label == "Move")
        #expect(RestackObjects([f.rect, f.text], into: f.top, at: 0).label == "Move 2 objects")
        f.replica.undo()
        #expect(f.tree.children(of: f.art) == [f.text, f.group, f.rect], "one undo step")
    }

    @Test func movingIntoAndOutOfAGroupKeepsThePlaceOnThePage() throws {
        var f = try Fixture()
        let before = try #require(Objects.bounds(of: f.rect, in: f.replica.state))
        try f.replica.perform(RestackObjects([f.rect], into: f.group, at: 1))
        #expect(f.tree.children(of: f.group) == [f.members[1], f.rect, f.members[0]])
        #expect(Objects.bounds(of: f.rect, in: f.replica.state) == before)
        #expect(Objects.transform(of: f.rect, in: f.replica.state).tx == -100, "the group's translation is undone in its space")
        let member = f.members[1]
        let memberBefore = try #require(Objects.bounds(of: member, in: f.replica.state))
        try f.replica.perform(RestackObjects([member], into: f.top, at: 0))
        #expect(f.tree.children(of: f.top) == [member])
        #expect(Objects.bounds(of: member, in: f.replica.state) == memberBefore)
    }

    @Test func refusedMovesChangeNothing() throws {
        var f = try Fixture()
        // Into itself or its own member; a non-container; a structural child's parent.
        #expect(try f.replica.perform(RestackObjects([f.group], into: f.group, at: 0)) == nil)
        #expect(throws: ObjectEditError.self) { try f.replica.perform(RestackObjects([f.rect], into: f.members[0], at: 0)) }
        #expect(throws: ObjectEditError.self) { try f.replica.perform(RestackObjects([f.group], into: f.rect, at: 0)) }
        // A locked object stays; a locked layer takes nothing.
        try f.replica.perform(SetLocked([f.rect], locked: true))
        #expect(try f.replica.perform(RestackObjects([f.rect], into: f.top, at: 0)) == nil)
        try f.replica.perform(SetLayerFlag([f.top], .locked, true))
        #expect(try f.replica.perform(RestackObjects([f.text], into: f.top, at: 0)) == nil)
        // A locked group takes nothing.
        try f.replica.perform(SetLocked([f.group], locked: true))
        #expect(try f.replica.perform(RestackObjects([f.text], into: f.group, at: 0)) == nil)
        // A group and its own member: the member goes with the group.
        try f.replica.perform(SetLocked([f.group], locked: false))
        try f.replica.perform(SetLayerFlag([f.top], .locked, false))
        try f.replica.perform(RestackObjects([f.group, f.members[0]], into: f.top, at: 0))
        #expect(f.tree.children(of: f.top) == [f.group] && f.tree.children(of: f.group).count == 2)
    }

    @Test func dragsOnTwoReplicasMerge() throws {
        var pair = Pair()
        let layers = try LayerFixture.layers(["Art", "Top"], on: &pair.a)
        let one = try LayerFixture.object(LayerFixture.rect(on: layers[0]), on: &pair.a)
        let two = try LayerFixture.object(LayerFixture.rect(on: layers[0], x: 20), on: &pair.a)
        pair.sync()
        // Different objects: both moves apply.
        try pair.a.perform(RestackObjects([one], into: layers[1], at: 0))
        try pair.b.perform(RestackObjects([two], into: layers[0], at: 1))
        pair.sync()
        #expect(ObjectTree(pair.a.state).children(of: layers[1]) == [one])
        #expect(ObjectTree(pair.a.state).children(of: layers[0]) == ObjectTree(pair.b.state).children(of: layers[0]))
        // The same object to two places: one wins on both.
        try pair.a.perform(RestackObjects([two], into: layers[1], at: 0))
        try pair.b.perform(RestackObjects([two], into: layers[0], at: 0))
        pair.sync()
        #expect(ObjectTree(pair.a.state).parent(of: two) == ObjectTree(pair.b.state).parent(of: two))
    }

    @Test func objectsOnARemovedLayerShowWhereTheyAreRouted() throws {
        var f = try Fixture()
        try f.replica.perform(MergeLayers([f.top, f.art]))
        let order = LayerOrder(f.replica.state)
        let target = try #require(order.isLive(f.art) ? f.art : f.top)
        #expect(f.tree.children(of: target).count == 3)
        #expect(f.tree.children(of: target == f.art ? f.top : f.art).isEmpty, "a deleted layer has no rows")
    }

    @Test func searchShowsMatchesWithTheRowsAboveThem() throws {
        var f = try Fixture()
        try f.replica.perform(SetNameOrNote([f.members[0]], .name, "Café sign"))
        let shown = f.tree.matching("cafe")
        #expect(shown == [f.art, f.group, f.members[0]])
        #expect(f.tree.matching("  ").isEmpty)
        #expect(f.tree.matching("hello") == [f.art, f.text])
        #expect(f.tree.matching("Art").isEmpty, "layers are not matched themselves")
    }

    /// A layer of `count` objects in groups of ten: listing the layer and one group, labelling a
    /// screenful of rows, and a search over every object, timed against the panel's frame.
    @Test func aLargeDocumentReadsInAFrame() throws {
        let count = PerfBudget.isMeasuring ? 5_000 : 500
        var replica = Replica(0xC)
        let layer = try LayerFixture.layers(["Art"], on: &replica)[0]
        var ops: [Wiretuner_Doc_V1_Op] = []
        var position: [UInt8]? = nil
        for _ in 0..<(count / 10) {
            let key = try PathEditing.keys(between: position, and: nil, count: 1)[0]
            position = key
            var group = Wiretuner_Doc_V1_NodeProps()
            group.group.kind = .group
            ops.append(Ops.create(parent: layer, position: key, props: group))
        }
        let groups = try replica.perform(OpsCommand("Groups", ops: ops))!.createdNodes
        for group in groups {
            var members: [Wiretuner_Doc_V1_Op] = []
            let keys = try PathEditing.keys(between: nil, and: nil, count: 10)
            for key in keys {
                var rect = Wiretuner_Doc_V1_NodeProps()
                rect.rect.size.width = 10
                rect.rect.size.height = 10
                members.append(Ops.create(parent: group, position: key, props: rect))
            }
            try replica.perform(OpsCommand("Members", ops: members))
        }
        let clock = ContinuousClock()
        var rows: [OpID] = []
        var labels: [String] = []
        let open = clock.measure {
            let tree = ObjectTree(replica.state)
            rows = tree.children(of: layer)
            let members = tree.children(of: rows[0])
            labels = (rows.prefix(40) + members).map { tree.label(of: $0) }
        }
        #expect(rows.count == count / 10 && labels.count == 50)
        var shown: Set<OpID> = []
        let search = clock.measure { shown = ObjectTree(replica.state).matching("rect") }
        #expect(shown.count == count + count / 10 + 1)
        print("Layers panel tree, \(count) objects: open \(open), search \(search)")
        PerfBudget.expect(open, within: .milliseconds(16), "open a layer of \(count / 10) groups")
        PerfBudget.expect(search, within: .milliseconds(250), "search \(count) objects")
    }

    /// A layer of 50,000 objects (the design point; the Layers panel's 50,000-object drag): moving
    /// one object to the front, one to the back and 1,000 scattered ones to the front each read
    /// the layer's order once (WTCRDT keeps it; `stackingOrder` indexes it per call).  The command
    /// alone is timed (`execute`), then the whole perform.
    @Test func restackingInALayerOfFiftyThousandObjectsReadsTheOrderOnce() throws {
        let count = 50_000
        var replica = Replica(0xD)
        let layer = try LayerFixture.layers(["Art"], on: &replica)[0]
        let keys = try PathEditing.keys(between: nil, and: nil, count: count)
        let ops = keys.map { key -> Wiretuner_Doc_V1_Op in
            var rect = Wiretuner_Doc_V1_NodeProps()
            rect.rect.size.width = 10
            rect.rect.size.height = 10
            return Ops.create(parent: layer, position: key, props: rect)
        }
        let created = try replica.perform(OpsCommand("Objects", ops: ops))
        let objects = try #require(created).createdNodes
        #expect(ObjectTree(replica.state).children(of: layer) == objects.reversed())
        let clock = ContinuousClock()
        var figures: [String] = []
        func restack(_ name: String, _ nodes: [OpID], at index: Int, budget: Duration) throws {
            let command = RestackObjects(nodes, into: layer, at: index)
            var builder = ChangeBuilder(replica: 0xD, startCounter: 1)
            let state = replica.state
            let execute = try clock.measure { try command.execute(&builder, state: state) }
            #expect(builder.ops.count == nodes.count)
            let perform = try clock.measure { try replica.perform(command) }
            figures.append("\(name): execute \(execute), perform \(perform)")
            PerfBudget.expect(execute, within: budget, "restack 50,000: \(name)")
        }
        try restack("bottom to front", [objects[0]], at: 0, budget: .milliseconds(16))
        var rows = ObjectTree(replica.state).children(of: layer)
        #expect(rows.first == objects[0] && rows.count == count)
        try restack("top to back", [objects[count - 1]], at: count, budget: .milliseconds(16))
        rows = ObjectTree(replica.state).children(of: layer)
        #expect(rows.last == objects[count - 1])
        let scattered = stride(from: 7, to: count, by: 50).map { objects[$0] }
        try restack("1,000 to front", scattered.reversed(), at: 0, budget: .milliseconds(50))
        rows = ObjectTree(replica.state).children(of: layer)
        // Frontmost first, keeping their stacking order among themselves: the topmost of them on top.
        #expect(Array(rows.prefix(scattered.count)) == scattered.reversed())
        #expect(Set(rows) == Set(objects))
        print("Restack in a layer of 50,000 objects -- " + figures.joined(separator: "; "))
    }
}
