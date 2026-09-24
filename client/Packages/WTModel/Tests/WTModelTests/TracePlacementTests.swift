import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

/// IMG-023's model half: the traced paths as one group directly above the traced object.
@Suite struct TracePlacementTests {
    static func group(_ name: String = "Trace of Photo") -> ImportedGroup {
        let square = ImportedContour(start: Point(x: 0, y: 0), segments: [.line(to: Point(x: 10, y: 0)), .line(to: Point(x: 10, y: 10)), .line(to: Point(x: 0, y: 10))],
                                     closed: true)
        let path = ImportedPath(contours: [square], fill: .solid(Color(red: 1, green: 0, blue: 0)))
        return ImportedGroup(children: [.path(path)], name: name)
    }

    @Test func theGroupGoesDirectlyAboveTheTracedObject() throws {
        var a = Replica(0xC)
        let layer = try NavigationFixture.layer(&a)
        let below = try NavigationFixture.rect(&a, on: layer)
        let above = try NavigationFixture.rect(&a, on: layer, x: 50)
        let change = try #require(try a.perform(PlaceTrace(Self.group(), above: below)))
        #expect(change.label == "Trace")
        let children = a.state.liveChildren(layer)
        #expect(children.count == 3 && children[0] == below && children[2] == above)
        #expect(a.state.store.kind(children[1]) == NodeKind.group.rawValue && a.state.props(children[1]).group.common.name == "Trace of Photo")
        // Above the topmost object: the new top.
        let topmost = try #require(try a.perform(PlaceTrace(Self.group("Over"), above: above)))
        #expect(a.state.liveChildren(layer).last == topmost.createdObjects.first)
        // Nothing under the marquee: the top of the current layer.
        let top = try #require(try a.perform(PlaceTrace(Self.group("Trace"), layer: layer)))
        #expect(a.state.liveChildren(layer).last == top.createdObjects.first)
        // A document without layers gets one.
        var b = Replica(0xD)
        try b.perform(PlaceTrace(Self.group()))
        #expect(LayerOrder(b.state).layers.count == 1)
        #expect(throws: TraceError.nothingTraced) { try a.perform(PlaceTrace(ImportedGroup(children: []))) }
    }
}
