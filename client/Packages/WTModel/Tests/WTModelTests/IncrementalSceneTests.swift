import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import WTText

/// D-094: a patched scene is the scene a full build makes.  Random edit sequences -- create,
/// delete, restack, group and ungroup, clip, rename, recolour, move, layer moves, master edits,
/// layer flags and renames, undo -- are applied to a patching builder and to a reference builder
/// that builds the whole scene for every change; after every step both scenes equal a fresh
/// rebuild (display list order and items, objects with their item paths, top-level order,
/// layers), the lookups agree, and both summaries are the same.
@Suite struct IncrementalSceneTests {
    /// SplitMix64: the same sequence on every run for a seed.
    struct Random: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A replica with a patching and a reference builder kept up to date with it.
    struct Harness {
        var replica: Replica
        var patched = DocumentDisplayListBuilder(canvas: "c")
        var reference = DocumentDisplayListBuilder(canvas: "c")
        var steps = 0
        var labels: [String] = []

        init(_ replica: Replica) {
            self.replica = replica
            reference.incremental = false
            patched.rebuild(replica.state)
            reference.rebuild(replica.state)
        }

        var state: EngineState { replica.state }

        /// Performs `command` and checks the builders; false when it wrote nothing or failed.
        @discardableResult
        mutating func perform(_ command: any Command, _ label: String) -> Bool {
            guard let change = (try? replica.perform(command)) ?? nil else { return false }
            check(change, label)
            return true
        }

        mutating func undo() {
            guard let change = replica.undo() else { return }
            check(change, "undo")
        }

        mutating func check(_ change: Wiretuner_Doc_V1_Change, _ label: String, origin: ChangeOrigin = .local) {
            let (scene, summary) = patched.apply(change, state: state, origin: origin)
            let (expected, expectedSummary) = reference.apply(change, state: state, origin: origin)
            steps += 1
            labels.append(label)
            Self.expectSame(scene, expected, label)
            #expect(summary == expectedSummary, "summary after \(label)")
            expectFresh(scene, label)
        }

        /// The patched scene is a fresh build's, and so are its dependencies.
        func expectFresh(_ scene: DocumentScene, _ label: String) {
            var fresh = DocumentDisplayListBuilder(canvas: "c")
            fresh.locallyHidden = patched.locallyHidden
            fresh.textLayout = patched.textLayout
            fresh.guideColor = patched.guideColor
            let full = fresh.rebuild(state)
            Self.expectSame(scene, full, "\(label) (fresh)")
            #expect(patched.dependencies == fresh.dependencies, "dependencies after \(label)")
        }

        /// Hides exactly `hidden` on this Mac in both builders.
        mutating func hide(_ hidden: Set<OpID>) {
            let changed = hidden.symmetricDifference(patched.locallyHidden)
            patched.locallyHidden = hidden
            reference.locallyHidden = hidden
            let (scene, summary) = patched.invalidate(changed, state: state)
            let (expected, expectedSummary) = reference.invalidate(changed, state: state)
            Self.expectSame(scene, expected, "hide")
            #expect(summary == expectedSummary, "summary after hiding")
            expectFresh(scene, "hide")
        }

        static func expectSame(_ scene: DocumentScene, _ expected: DocumentScene, _ label: String) {
            #expect(scene.displayList == expected.displayList, "display list after \(label)")
            #expect(scene.topLevel == expected.topLevel, "top level after \(label)")
            #expect(scene.layers == expected.layers, "layers after \(label)")
            #expect(scene.objects.keys.sorted() == expected.objects.keys.sorted(), "object ids after \(label)")
            for (id, object) in expected.objects where scene.objects[id] != object {
                Issue.record("object \(id) differs after \(label): \(String(describing: scene.objects[id]?.itemPath)) vs \(object.itemPath)")
            }
            #expect(scene == expected, "scene after \(label)")
            let list = scene.displayList, other = expected.displayList
            #expect(list.itemBounds == other.itemBounds && list.bounds == other.bounds && list.lensIndices == other.lensIndices,
                    "list bounds after \(label)")
            for (index, node) in other.nodeIDs.enumerated() {
                if let node { #expect(list.index(of: node) == index, "index of \(node) after \(label)") }
            }
            for object in expected.objects.values {
                #expect(scene.object(atItemPath: object.itemPath)?.id == object.id, "item path of \(object.id) after \(label)")
                for alias in object.aliasItemPaths {
                    #expect(scene.object(atItemPath: alias)?.id == object.id, "alias of \(object.id) after \(label)")
                }
            }
        }
    }

    /// Layers Back and Front with master content on child pages (`MasterRenderingTests`), a
    /// group, a clip group, a connector between two boxes and a blend.
    static func fixture() throws -> (Harness, masterObjects: [OpID], layers: [OpID]) {
        var setup = try MasterRenderingTests.Fixture()
        var a = setup.a
        _ = try ClipRenderingTests.fixture(on: &a)
        let first = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 12, height: 12), transform: .translation(x: 300, y: 10)), on: &a)
        let second = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 12, height: 12), transform: .translation(x: 330, y: 10)), on: &a)
        try a.perform(GroupObjects([first, second]))
        let left = try ConnectorTests.Boxes.box(&a, x: 400, y: 0)
        let right = try ConnectorTests.Boxes.box(&a, x: 480, y: 40)
        try a.perform(CreateConnector(start: ConnectorEnd(node: NodeID(left), side: .right, point: Point(x: 421, y: 10)),
                                      end: ConnectorEnd(node: NodeID(right), side: .left, point: Point(x: 479, y: 50))))
        let key1 = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10), transform: .translation(x: 600, y: 0),
                                                       appearance: CombineCommandTests.filled(0.2)), on: &a)
        let key2 = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 20), transform: .translation(x: 700, y: 80),
                                                       appearance: CombineCommandTests.filled(0.8)), on: &a)
        try a.perform(Blend([key1, key2]))
        setup.a = a
        return (Harness(a), [setup.masterBack, setup.masterFront], [setup.back, setup.front])
    }

    /// One random edit.
    static func step(_ harness: inout Harness, _ random: inout Random, masterObjects: [OpID], layers: [OpID]) {
        let state = harness.state
        let objects = harness.reference.scene.objects.keys.sorted().map(OpID.init)
        let any = { (random: inout Random) -> OpID? in objects.randomElement(using: &random) }
        let groups = objects.filter { state.nodeKind($0) == .group }
        let liveLayers = LayerOrder(state).layers.filter { $0.role == .ordinary }.map(\.id)
        let red = Double(Int.random(in: 0...9, using: &random)) / 9
        switch Int.random(in: 0..<23, using: &random) {
        case 0, 1:
            let shape: CreateShape.Kind = Bool.random(using: &random) ? .rectangle(CornerRadii()) : .ellipse
            let at = Point(x: Double.random(in: -50...800, using: &random).rounded(), y: Double.random(in: -50...300, using: &random).rounded())
            harness.perform(CreateShape(shape, size: Size(width: 15, height: 10), transform: .translation(x: at.x, y: at.y),
                                        appearance: CombineCommandTests.filled(red), layer: liveLayers.randomElement(using: &random)), "create")
        case 2:
            if let node = any(&random) { harness.perform(ClearObjects([node]), "delete") }
        case 3:
            if let node = any(&random) {
                harness.perform(Arrange([node], Arrange.Direction.allCases.randomElement(using: &random)!), "arrange")
            }
        case 4:
            if let node = any(&random), let parent = (groups + liveLayers).randomElement(using: &random) {
                harness.perform(RestackObjects([node], into: parent, at: Int.random(in: 0...6, using: &random)), "restack")
            }
        case 5:
            let picked = (0..<Int.random(in: 2...3, using: &random)).compactMap { _ in any(&random) }
            harness.perform(GroupObjects(Array(Set(picked))), "group")
        case 6:
            if let group = groups.randomElement(using: &random) { harness.perform(Ungroup([group]), "ungroup") }
        case 7:
            let paths = objects.filter { PasteContents.accepts($0, in: state) }
            if let target = paths.randomElement(using: &random), let content = any(&random), content != target,
               !Objects.editable([content], in: state).isEmpty {
                let payload = ClipboardPayload(copying: [content], from: state)
                if harness.perform(CutObjects([content]), "cut") { harness.perform(PasteContents(payload, into: target), "paste contents") }
            }
        case 8:
            if let node = any(&random) { harness.perform(SetNameOrNote([node], .name, "N\(Int.random(in: 0...99, using: &random))"), "rename") }
        case 9:
            if let node = any(&random) {
                harness.perform(ApplyColor([node], target: .fill, color: Appearances.inline(red: red, green: 0.5, blue: 0)), "recolour")
            }
        case 10, 11:
            if let node = any(&random) {
                harness.perform(MoveObjects([node], by: Vector(dx: Double(Int.random(in: -20...20, using: &random)), dy: 7)), "move")
            }
        case 12:
            if let node = any(&random), let layer = liveLayers.randomElement(using: &random) {
                harness.perform(MoveObjectsToLayer([node], to: layer), "to layer")
            }
        case 13:
            if let node = masterObjects.randomElement(using: &random) {
                if Bool.random(using: &random) {
                    harness.perform(MoveObjects([node], by: Vector(dx: 3, dy: -2)), "master move")
                } else {
                    harness.perform(ApplyColor([node], target: .fill, color: Appearances.inline(red: red, green: 0, blue: 1)), "master recolour")
                }
            }
        case 14:
            if let layer = layers.randomElement(using: &random) {
                harness.perform(RenameLayer(layer, to: "L\(Int.random(in: 0...9, using: &random))"), "layer rename")
            }
        case 15:
            if let layer = layers.randomElement(using: &random) {
                let flag = SetLayerFlag.Flag.allCases.filter { $0 != .printing }.randomElement(using: &random)!
                harness.perform(SetLayerFlag([layer], flag, !(LayerOrder(state).layer(layer).map { info in
                    switch flag {
                    case .visible: info.visible
                    case .locked: info.locked
                    case .keyline: info.keyline
                    case .printing: info.printing
                    }
                } ?? false)), "layer flag")
            }
        case 16:
            if let start = any(&random), let end = any(&random), start != end {
                harness.perform(CreateConnector(start: ConnectorEnd(node: NodeID(start), point: .zero), end: ConnectorEnd(node: NodeID(end), point: .zero)),
                                "connect")
            }
        case 17:
            let shapes = objects.filter { [.rect, .ellipse, .path].contains(state.nodeKind($0)) }
            if let first = shapes.randomElement(using: &random), let second = shapes.randomElement(using: &random), first != second {
                harness.perform(Blend([first, second]), "blend")
            }
        case 18:
            if Int.random(in: 0..<3, using: &random) == 0 {
                harness.perform(CreateLayer(name: "New", above: liveLayers.randomElement(using: &random)), "new layer")
            } else if liveLayers.count > 2 {
                harness.perform(MergeLayers(Array(liveLayers.shuffled(using: &random).prefix(2))), "merge layers")
            }
        case 19:
            if let layer = layers.randomElement(using: &random) {
                var moved = Wiretuner_Doc_V1_NodeProps()
                moved.layer.common.transform = PathEditing.proto(AffineTransform.translation(x: Double(Int.random(in: -9...9, using: &random)), y: 0))
                harness.perform(OpsCommand("Move layer", ops: [Ops.set(layer, [RegisterPath([150, 1, 4])], values: moved)]), "layer transform")
            }
        default:
            harness.undo()
        }
    }

    @Test func remoteTreeOpsMergedOutOfOrderBuildInFull() throws {
        var a = Replica(1)
        let x = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 10, height: 10)), on: &a)
        let y = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 10, height: 10), transform: .translation(x: 40, y: 0)), on: &a)
        let z = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 10, height: 10), transform: .translation(x: 80, y: 0)), on: &a)
        let first = try #require(try a.perform(GroupObjects([x]))).createdObjects[0]
        let second = try #require(try a.perform(GroupObjects([y]))).createdObjects[0]
        var b = Replica(2)
        b.receive(a.sent)
        var harness = Harness(a)
        // Concurrently: here the first group goes into the second; there the second into the
        // first.  Here another op follows, so the remote move arrives older than it.
        let layer = try #require(harness.state.store.placement(z)?.parent)
        harness.perform(RestackObjects([first], into: second, at: 0), "local move")
        harness.perform(Arrange([z], .sendToBack), "local arrange")
        let remote = try #require(try b.perform(RestackObjects([second], into: first, at: 0)))
        let patches = harness.patched.patches
        harness.replica.receive([remote])
        harness.check(remote, "remote move", origin: .remote)
        #expect(harness.patched.patches == patches, "an out-of-order tree op is built in full")
        #expect(!DocumentDisplayListBuilder.treeOpsInOrder(remote, state: harness.state))
        // A remote edit that is not a tree op patches.
        let rename = try #require(try b.perform(SetNameOrNote([z], .name, "Z")))
        harness.replica.receive([rename])
        harness.check(rename, "remote rename", origin: .remote)
        #expect(harness.patched.patches == patches + 1)
        _ = layer
    }

    @Test func hidingOnThisMacPatches() throws {
        var (harness, _, _) = try Self.fixture()
        let objects = harness.reference.scene.objects.keys.sorted().map(OpID.init)
        let member = try #require(objects.first { harness.reference.scene.objects[NodeID($0)]?.parent != nil })
        let top = try #require(harness.reference.scene.topLevel.last.map(OpID.init))
        let patches = harness.patched.patches
        harness.hide([member, top])
        harness.hide([top])
        harness.hide([])
        #expect(harness.patched.patches == patches + 3)
    }

    @Test func symbolEditsReachTheirInstances() throws {
        var a = Replica(7)
        let (symbol, instance, masters) = try SymbolFixture.converted(on: &a)
        var harness = Harness(a)
        let patches = harness.patched.patches
        harness.perform(ApplyColor([masters[0]], target: .fill, color: Appearances.inline(red: 0, green: 0, blue: 1)), "master recolour")
        harness.perform(MoveObjects([masters[1]], by: Vector(dx: 5, dy: 0)), "master move")
        harness.perform(MoveObjects([instance], by: Vector(dx: 0, dy: 9)), "instance move")
        harness.perform(SetNameOrNote([symbol], .name, "Renamed"), "symbol rename")
        harness.undo()
        #expect(harness.patched.patches > patches)
    }

    @Test func aSymbolsCanvasBuildsInFullAndFindsItsMembers() throws {
        var a = Replica(7)
        let (symbol, _, masters) = try SymbolFixture.converted(on: &a)
        try a.perform(GroupObjects(masters))
        var builder = DocumentDisplayListBuilder(canvas: "symbol")
        builder.canvasNode = symbol
        let scene = builder.rebuild(a.state)
        #expect(scene.objects.count == 3)
        for object in scene.objects.values {
            #expect(scene.object(atItemPath: object.itemPath)?.id == object.id)
        }
        let patches = builder.patches
        let change = try #require(try a.perform(MoveObjects([masters[0]], by: Vector(dx: 4, dy: 0))))
        let (moved, _) = builder.apply(change, state: a.state, origin: .local)
        #expect(builder.patches == patches, "a symbol's canvas is built in full")
        var fresh = DocumentDisplayListBuilder(canvas: "symbol")
        fresh.canvasNode = symbol
        #expect(fresh.rebuild(a.state) == moved)
    }

    @Test @MainActor
    func textEditsPatch() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "Hello", at: Point(x: 100, y: 50))
        let fonts = DocumentFontIndex(state: a.state)
        var harness = Harness(a)
        harness.patched.textLayout = TextSceneLayout(engine: fonts.layoutEngine)
        harness.reference.textLayout = harness.patched.textLayout
        harness.patched.rebuild(harness.state)
        harness.reference.rebuild(harness.state)
        harness.perform(InsertText(node: node, text: " world", at: .end), "type")
        harness.perform(MoveObjects([node], by: Vector(dx: 3, dy: 3)), "move text")
        harness.perform(CreateShape(.ellipse, size: Size(width: 30, height: 30), transform: .translation(x: 90, y: 40)), "shape over text")
        harness.undo()
    }

    @Test func aSceneAssembledByHandFindsItsObjects() throws {
        let (harness, _, _) = try Self.fixture()
        let built = harness.patched.scene
        // Without node ids in its list: the top-level objects are found by their item paths.
        let list = DisplayList(canvas: "c", items: built.displayList.items, layers: built.displayList.layers)
        let assembled = DocumentScene(displayList: list, objects: built.objects, topLevel: built.topLevel, layers: built.layers)
        for object in built.objects.values {
            #expect(assembled.object(atItemPath: object.itemPath)?.id == object.id)
            for alias in object.aliasItemPaths { #expect(assembled.object(atItemPath: alias)?.id == object.id) }
        }
        #expect(assembled.object(atItemPath: []) == nil && assembled.object(atItemPath: [9999]) == nil)
        #expect(built.object(atItemPath: [9999]) == nil)
        // Equal scenes hash alike; the lookup tables are not part of either.
        let tagged = DocumentScene(displayList: built.displayList, objects: built.objects, topLevel: built.topLevel, layers: built.layers)
        #expect(tagged == built && Set([tagged, built]).count == 1)
    }

    @Test func aGuideColourOrALayerTransformBuildsInFull() throws {
        var (harness, _, layers) = try Self.fixture()
        var patches = harness.patched.patches
        harness.patched.guideColor = Color(red: 1, green: 0, blue: 1)
        harness.reference.guideColor = harness.patched.guideColor
        let renamed = try #require(try harness.replica.perform(RenameLayer(layers[0], to: "Renamed")))
        _ = harness.patched.apply(renamed, state: harness.state, origin: .local)
        _ = harness.reference.apply(renamed, state: harness.state, origin: .local)
        #expect(harness.patched.patches == patches, "a new guide colour builds in full")
        patches = harness.patched.patches
        var moved = Wiretuner_Doc_V1_NodeProps()
        moved.layer.common.transform = PathEditing.proto(AffineTransform.translation(x: 0, y: 30))
        harness.perform(OpsCommand("Move layer", ops: [Ops.set(layers[1], [RegisterPath([150, 1, 4])], values: moved)]),
                        "layer transform")
        #expect(harness.patched.patches == patches, "a layer's transform builds in full")
    }

    @Test func aRasterResolutionChangeBuildsInFull() throws {
        var (harness, _, _) = try Self.fixture()
        var settings = Wiretuner_Doc_V1_NodeProps()
        settings.settings.rasterEffects.resolutionPpi = 300
        let patches = harness.patched.patches
        harness.perform(OpsCommand("Resolution", ops: [Ops.set(WellKnown.settings, [RegisterPath([2, 90, 1])], values: settings)]), "resolution")
        #expect(harness.patched.patches == patches)
    }

    @Test func objectsShownFromADeletedLayerSortAfterTheLayersOwn() throws {
        var a = Replica(3)
        let layers = try LayerFixture.layers(["Back", "Front"], on: &a)
        _ = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 10, height: 10), layer: layers[0]), on: &a)
        _ = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 10, height: 10), transform: .translation(x: 20, y: 0), layer: layers[1]), on: &a)
        try a.perform(MergeLayers(layers))
        let order = LayerOrder(a.state)
        let deleted = try #require(layers.first { !order.isLive($0) })
        let live = try #require(order.displayLayer(for: deleted))
        var harness = Harness(a)
        // Objects added to the deleted layer (as a concurrent edit would) show on the live one,
        // after its own.
        var rect = Wiretuner_Doc_V1_NodeProps()
        rect.rect.size.width = 8
        rect.rect.size.height = 8
        rect.rect.common.transform.a = 1
        rect.rect.common.transform.d = 1
        var routed: [OpID] = []
        for position: UInt8 in [0x40, 0x80, 0xC0] {
            rect.rect.common.transform.tx = Double(position)
            let change = try #require(try harness.replica.perform(OpsCommand("Add", ops: [Ops.create(parent: deleted, position: [position], props: rect)])))
            harness.check(change, "routed add")
            routed.append(change.createdNodes[0])
        }
        harness.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 5, height: 5), layer: live), "own add")
        #expect(harness.patched.scene.topLevel.suffix(3) == routed.map(NodeID.init))
        harness.perform(MoveObjects([routed[1]], by: Vector(dx: 1, dy: 1)), "routed move")
        harness.perform(Arrange([routed[0]], .bringToFront), "routed arrange")
        harness.perform(ClearObjects([routed[2]]), "routed delete")
        harness.undo()
        #expect(harness.patched.patches >= 6)
    }

    @Test(arguments: Array(UInt64(1)...12))
    func randomEditsPatchToTheFullBuild(seed: UInt64) throws {
        var (harness, masterObjects, layers) = try Self.fixture()
        var random = Random(state: seed)
        for _ in 0..<200 {
            Self.step(&harness, &random, masterObjects: masterObjects, layers: layers)
        }
        print("D-094 seed \(seed): \(harness.steps) changes, \(harness.patched.patches) patched, \(harness.labels.sorted().joined(separator: " "))")
        #expect(harness.steps > 60, "most steps changed the document")
        #expect(harness.patched.patches > harness.steps / 2, "most changes were patched (\(harness.patched.patches) of \(harness.steps))")
    }
}
