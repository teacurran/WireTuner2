import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto

@Suite struct LibraryLayerMemoryTests {
    @Test func groupingAcrossThreeLayersRoundTrips() throws {
        for remember in [true, false] {
            var a = Replica(0xA)
            let layers = try LayerFixture.layers(["A", "B", "C"], on: &a)
            let objects = try layers.enumerated().map { index, layer in
                try LayerFixture.object(LayerFixture.rect(on: layer, x: Double(index) * 20), on: &a)
            }
            let group = try #require(try a.perform(GroupObjects(objects, layer: layers[1], rememberLayerInfo: remember))).createdObjects[0]
            let order = LayerOrder(a.state)
            #expect(objects.allSatisfy { order.layer(of: $0, in: a.state) == layers[1] })
            try a.perform(Ungroup([group], rememberLayerInfo: remember))
            let after = LayerOrder(a.state)
            let expected = remember ? layers : [layers[1], layers[1], layers[1]]
            #expect(objects.map { after.layer(of: $0, in: a.state) } == expected)
        }
    }

    @Test func crossDocumentPasteCreatesTheMissingLayerInTheSameChange() throws {
        var source = Replica(0xA)
        let sketch = try LayerFixture.layers(["Sketch"], on: &source)[0]
        let object = try LayerFixture.object(LayerFixture.rect(on: sketch), on: &source)
        let payload = ClipboardPayload(copying: [object], from: source.state, document: "doc-a")
        var target = Replica(0xB)
        let other = try LayerFixture.layers(["Other"], on: &target)[0]
        let change = try #require(try target.perform(Paste(payload, placement: .top(layer: other, center: nil), rememberLayerInfo: true)))
        let order = LayerOrder(target.state)
        let created = try #require(order.layers.first { $0.name == "Sketch" })
        #expect(change.createdNodes.contains(created.id))
        #expect(order.layers.map(\.name) == ["Other", "Sketch"])
        #expect(order.layer(of: change.createdObjects.last!, in: target.state) == created.id)
        // Off: the paste lands on the active layer and creates nothing.
        let plain = try #require(try target.perform(Paste(payload, placement: .top(layer: other, center: nil))))
        #expect(LayerOrder(target.state).layer(of: plain.createdObjects[0], in: target.state) == other)
        #expect(LayerOrder(target.state).layers.count == 2)
    }

    @Test func twoConcurrentPastesCreateTwoLayersOfOneName() throws {
        var source = Replica(0xC)
        let sketch = try LayerFixture.layers(["Sketch"], on: &source)[0]
        let payload = ClipboardPayload(copying: [try LayerFixture.object(LayerFixture.rect(on: sketch), on: &source)], from: source.state)
        var pair = Pair()
        let base = try LayerFixture.layers(["Base"], on: &pair.a)[0]
        pair.sync()
        try pair.a.perform(Paste(payload, placement: .top(layer: base, center: nil), rememberLayerInfo: true))
        try pair.b.perform(Paste(payload, placement: .top(layer: base, center: nil), rememberLayerInfo: true))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let order = LayerOrder(pair.a.state)
        let named = order.layers.filter { $0.name == "Sketch" }
        #expect(named.count == 2)
        #expect(named.allSatisfy { order.objects(on: $0.id, in: pair.a.state).count == 1 })
    }

    @Test func helpersRecordResolveAndCreate() throws {
        var a = Replica(0xA)
        let layers = try LayerFixture.layers(["Art", "Locked"], on: &a)
        try a.perform(SetLayerFlag([layers[1]], .locked, true))
        let object = try LayerFixture.object(LayerFixture.rect(on: layers[0]), on: &a)
        #expect(LayerMemory.originLayer(of: object, in: a.state) == nil)
        #expect(LayerMemory.restoreLayer(of: object, in: a.state) == nil)
        var builder = ChangeBuilder(replica: 0xA, startCounter: 100)
        LayerMemory.record([object, layers[0]], in: a.state, builder: &builder)
        #expect(builder.ops.count == 1)
        try a.perform(OpsCommand("Remember", ops: builder.ops))
        #expect(LayerMemory.originLayer(of: object, in: a.state) == "Art")
        #expect(LayerMemory.record(object, in: a.state) == nil)
        #expect(LayerMemory.restoreLayer(of: object, in: a.state) == layers[0])
        // A locked layer of the name takes nothing.
        try a.perform(OpsCommand("Rename", ops: [LayerMemory.write(object, kind: .rect, "Locked")]))
        #expect(LayerMemory.restoreLayer(of: object, in: a.state) == nil)
        try a.perform(OpsCommand("Clear", ops: [LayerMemory.write(object, kind: .rect, "")]))
        #expect(LayerMemory.originLayer(of: object, in: a.state) == nil)
        // An existing layer is found, a missing one created once per change.
        var created: [String: OpID] = [:]
        var create = ChangeBuilder(replica: 0xA, startCounter: 200)
        #expect(try LayerMemory.layer(named: "Art", above: nil, created: &created, state: a.state, builder: &create) == layers[0])
        let fresh = try LayerMemory.layer(named: "New", above: layers[0], created: &created, state: a.state, builder: &create)
        #expect(try LayerMemory.layer(named: "New", above: layers[0], created: &created, state: a.state, builder: &create) == fresh)
        #expect(create.ops.count == 1)
    }

    @Test func guideObjectsRememberAndReturn() throws {
        var a = Replica(0xA)
        let guides = try a.perform(LayerFixture.guides())!.createdNodes[0]
        let layers = try LayerFixture.layers(["Art", "Active"], on: &a)
        let object = try LayerFixture.object(LayerFixture.rect(on: layers[0]), on: &a)
        let other = try LayerFixture.object(LayerFixture.rect(on: layers[0], x: 30), on: &a)
        let convert = ConvertToGuides([object, other], rememberLayerInfo: true)
        #expect(convert.label == "Convert 2 objects to guides")
        try a.perform(convert)
        #expect(Objects.parent(of: object, in: a.state) == guides)
        #expect(LayerMemory.originLayer(of: object, in: a.state) == "Art")
        #expect(try a.perform(ConvertToGuides([object])) == nil)
        let release = ReleaseGuideObjects([object], layer: layers[1], rememberLayerInfo: true)
        #expect(release.label == "Release to Layer")
        try a.perform(release)
        #expect(Objects.parent(of: object, in: a.state) == layers[0])
        #expect(LayerMemory.originLayer(of: object, in: a.state) == nil)
        // Without the preference: the active layer, and the memory stays.
        try a.perform(ReleaseGuideObjects([other], layer: layers[1]))
        #expect(Objects.parent(of: other, in: a.state) == layers[1])
        #expect(LayerMemory.originLayer(of: other, in: a.state) == "Art")
        // Not on the Guides layer: nothing.
        #expect(try a.perform(ReleaseGuideObjects([other, object], rememberLayerInfo: true)) == nil)
        #expect(ReleaseGuideObjects([object, other]).label == "Release 2 objects to layers")
        #expect(ConvertToGuides([object]).label == "Convert to Guide")
        // Remembered layer gone: the fallback.
        try a.perform(ConvertToGuides([object], rememberLayerInfo: true))
        try a.perform(RemoveLayers([layers[0]]))
        try a.perform(ReleaseGuideObjects([object], layer: layers[1], rememberLayerInfo: true))
        #expect(Objects.parent(of: object, in: a.state) == layers[1])
        // A locked Guides layer refuses.
        try a.perform(SetLayerFlag([guides], .locked, true))
        #expect(throws: LayerError.lockedLayer(guides)) { try a.perform(ConvertToGuides([object])) }
    }

    @Test func noGuidesLayer() throws {
        var a = Replica(0xA)
        let layer = try LayerFixture.layers(["Art"], on: &a)[0]
        let object = try LayerFixture.object(LayerFixture.rect(on: layer), on: &a)
        #expect(throws: LayerError.guidesLayer) { try a.perform(ConvertToGuides([object])) }
        #expect(try a.perform(ReleaseGuideObjects([object])) == nil)
    }
}
