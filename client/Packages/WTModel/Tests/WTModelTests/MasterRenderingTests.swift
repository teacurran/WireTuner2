import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// DOC-011: master content on child pages (master-pages.adoc, "Client").
@Suite struct MasterRenderingTests {
    /// Layers Back and Front; page 1 at (100, 50) with a rectangle on each layer, converted to a
    /// master (so page 1 is its child); page 2, also a child, placed after it; and a child object
    /// on page 1's Front layer.
    struct Fixture {
        var a = Replica(0xA)
        var back: OpID, front: OpID
        var page: OpID, second: OpID, master: OpID
        var masterBack: OpID, masterFront: OpID, childObject: OpID

        init() throws {
            let layers = try LayerFixture.layers(["Back", "Front"], on: &a)
            back = layers[0]
            front = layers[1]
            page = try PageFixture.onePage(&a)
            try a.perform(MovePage(page, by: Vector(dx: 100, dy: 50), withContents: false))
            masterBack = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 20),
                                                             transform: .translation(x: 110, y: 60), layer: back), on: &a)
            masterFront = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 10, height: 10), transform: .translation(x: 150, y: 60),
                                                              layer: front), on: &a)
            try a.perform(ConvertToMasterPage(page))
            master = PageList(a.state).masters[0].id
            try a.perform(AddPages(count: 1, master: .some(master), after: page))
            second = PageList(a.state).pages[1].id
            childObject = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 30, height: 30),
                                                              transform: .translation(x: 105, y: 55), appearance: CombineCommandTests.filled(0.5),
                                                              layer: front), on: &a)
        }

        var origins: [Point] { PageList(a.state).pages.map(\.origin) }
    }

    static func scene(_ state: EngineState) -> (DocumentDisplayListBuilder, DocumentScene) {
        var builder = DocumentDisplayListBuilder(canvas: "main")
        let scene = builder.rebuild(state)
        return (builder, scene)
    }

    /// The top-level items of `layer`'s run in `list`, as (item, node) pairs.
    static func run(_ list: DisplayList, layer: OpID) -> [(DisplayItem, NodeID?)] {
        guard let span = list.layers.first(where: { $0.layer.id == NodeID(layer) }) else { return [] }
        return span.range.map { (list.items[$0], list.nodeIDs[$0]) }
    }

    static func inertGroups(_ run: [(DisplayItem, NodeID?)]) -> [GroupItem] {
        run.compactMap { item, node in
            guard node == nil, case .group(let group) = item, group.inert else { return nil }
            return group
        }
    }

    @Test func masterObjectsDrawBelowTheChildsObjectsOnEachOfTheirLayers() throws {
        let f = try Fixture()
        let (_, scene) = Self.scene(f.a.state)
        let backRun = Self.run(scene.displayList, layer: f.back)
        let frontRun = Self.run(scene.displayList, layer: f.front)
        // One inert group per child page on each layer holding master content.
        #expect(Self.inertGroups(backRun).count == 2 && Self.inertGroups(frontRun).count == 2)
        // On Front the master content comes first, the child's object after it.
        #expect(frontRun.map(\.1) == [nil, nil, NodeID(f.childObject)])
        // Translated by each page's origin: master (10, 10) → page origin + (10, 10).
        let origins = f.origins
        let backGroups = Self.inertGroups(backRun)
        for (group, origin) in zip(backGroups, origins) {
            let bounds = try #require(group.children.first?.bounds)
            // (The standard 1 pt stroke's bounds pad by 2.)
            #expect(abs(bounds.minX - (origin.x + 8)) < 0.01 && abs(bounds.minY - (origin.y + 8)) < 0.01)
        }
        // Master objects are not objects of the pasteboard scene.
        #expect(scene.object(f.masterBack) == nil && scene.object(f.childObject) != nil)
    }

    @Test func masterContentIsNeverHitOnAChild() throws {
        let f = try Fixture()
        let (_, scene) = Self.scene(f.a.state)
        let viewport = Viewport(zoom: 1, size: Size(width: 2000, height: 2000))
        for options in [HitOptions(), HitOptions(subselect: true)] {
            let tester = HitTester(displayList: scene.displayList, viewport: viewport, options: options)
            // Over the master rectangle on page 2, where the child has no object: nothing.
            #expect(tester.hitTest(viewPoint: Point(x: 812, y: 70)).isEmpty)
            // Over both: the child's object.
            let hits = tester.hitTest(viewPoint: Point(x: 115, y: 65)).compactMap { scene.object(atItemPath: $0.itemPath)?.id }
            #expect(hits == [f.childObject])
            #expect(tester.hitTest(marquee: Rect(x: 100, y: 50, width: 60, height: 40)).allSatisfy { scene.object(atItemPath: $0.itemPath) != nil })
        }
    }

    @Test func aRemoteEditToAMasterObjectRepaintsOnlyItsRectOnEveryChild() throws {
        var pair = Pair()
        var f = try Fixture()
        pair.a = f.a
        pair.b.receive(f.a.sent)
        var builder = DocumentDisplayListBuilder(canvas: "main")
        builder.rebuild(pair.b.state)
        let change = try #require(try pair.a.perform(MoveObjects([f.masterFront], by: Vector(dx: 3, dy: 0))))
        pair.b.receive([change])
        let (after, summary) = builder.apply(change, state: pair.b.state, origin: .remote)
        let origins = PageList(pair.b.state).pages.map(\.origin)
        for (page, origin) in zip([f.page, f.second], origins) {
            let bounds = try #require(summary.bounds[NodeID(page)])
            let old = try #require(bounds.old?.rect), new = try #require(bounds.new?.rect)
            // Only the ellipse's rectangle (master (50, 10) 10 × 10, stroke included), not the
            // whole master content.
            #expect(old.width <= 14.01 && new.width <= 14.01)
            #expect(abs(old.minX - (origin.x + 48)) < 0.01 && abs(new.minX - (origin.x + 51)) < 0.01)
        }
        #expect(summary.bounds[NodeID(f.childObject)] == nil, "the child's own objects are untouched")
        let front = Self.inertGroups(Self.run(after.displayList, layer: f.front))
        #expect(abs((front.first?.children.first?.bounds?.minX ?? 0) - (origins[0].x + 51)) < 0.01)
        f.a = pair.a
    }

    @Test func detachingAPageOrMovingItRepaintsItsWholeMasterContent() throws {
        var f = try Fixture()
        var builder = DocumentDisplayListBuilder(canvas: "main")
        builder.rebuild(f.a.state)
        let change = try #require(try f.a.perform(DetachFromMaster([f.second])))
        let (scene, summary) = builder.apply(change, state: f.a.state, origin: .local)
        let bounds = try #require(summary.bounds[NodeID(f.second)])
        #expect(bounds.old != nil && bounds.new == nil)
        #expect(Self.inertGroups(Self.run(scene.displayList, layer: f.back)).count == 1)
        #expect(summary.isStructural)
        // Deleting the master removes its content from every page.
        let delete = try #require(try f.a.perform(DeleteMasterPage(f.master)))
        let (cleared, _) = builder.apply(delete, state: f.a.state, origin: .local)
        #expect(Self.inertGroups(Self.run(cleared.displayList, layer: f.back)).isEmpty)
    }

    @Test func printAndExportClipToTheBleedRectangle() throws {
        var f = try Fixture()
        try f.a.perform(SetBleed([f.master], to: 9))
        var builder = DocumentDisplayListBuilder(canvas: "main")
        builder.rebuild(f.a.state)
        let output = builder.outputDisplayList(f.a.state)
        let groups = Self.inertGroups(Self.run(output, layer: f.back))
        let page = PageList(f.a.state).pages[0]
        #expect(groups.count == 2)
        #expect(groups[0].clip?.controlBounds == page.bleedRect)
        // A builder asked for output first prepares the masters itself; the screen never clips.
        var fresh = DocumentDisplayListBuilder(canvas: "print")
        #expect(Self.inertGroups(Self.run(fresh.outputDisplayList(f.a.state), layer: f.back)).count == 2)
        #expect(Self.inertGroups(Self.run(builder.scene.displayList, layer: f.back)).allSatisfy { $0.clip == nil })
    }

    @Test func theMastersOwnCanvasDrawsItsObjectsInMasterCoordinatesWithoutMasterContent() throws {
        let f = try Fixture()
        var builder = DocumentDisplayListBuilder(canvas: "master")
        builder.canvasNode = f.master
        let scene = builder.rebuild(f.a.state)
        #expect(scene.object(f.masterBack)?.bounds?.minX ?? 0 < 11)
        #expect(scene.displayList.items.allSatisfy { if case .group(let group) = $0 { !group.inert } else { true } })
    }
}
