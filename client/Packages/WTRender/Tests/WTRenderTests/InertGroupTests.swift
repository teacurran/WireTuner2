import Testing
import WTGeometry
@testable import WTRender

/// DOC-011: inert groups (master content on a child page) draw but are never hit.
@Suite struct InertGroupTests {
    @Test func inertGroupsAreNeverHitByAClickOrAMarquee() {
        var inert = GroupItem(children: [ClipMasterCorpus.masterContent])
        inert.inert = true
        let above = ReferenceCorpus.path(DisplayPath(rect: Rect(x: 50, y: 50, width: 10, height: 10)), [ReferenceCorpus.fill(.black)])
        let list = DisplayList(canvas: "inert", items: [.group(inert), above])
        for options in [HitOptions(), HitOptions(subselect: true)] {
            let tester = HitTester(displayList: list, viewport: Viewport(size: Size(width: 200, height: 200)), options: options)
            #expect(tester.hitTest(viewPoint: Point(x: 20, y: 45)).isEmpty, "over the master band only")
            #expect(tester.hitTest(viewPoint: Point(x: 55, y: 55)).map(\.itemPath) == [[1]])
            #expect(tester.hitTest(marquee: Rect(x: 0, y: 0, width: 150, height: 150)).map(\.itemPath) == [[1]])
        }
        #expect(!GroupItem(children: []).inert)
    }

    @Test func theClipGroupSlotsClipOnlyTheContents() {
        let tester = HitTester(displayList: DisplayList(canvas: "clip", items: [ClipMasterCorpus.clipGroup]),
                               viewport: Viewport(size: Size(width: 200, height: 200)), options: HitOptions(subselect: true))
        // The magenta bar outside the clip is not hit; inside it is.
        #expect(tester.hitTest(viewPoint: Point(x: 110, y: 60)).isEmpty)
        #expect(tester.hitTest(viewPoint: Point(x: 50, y: 40)).first?.itemPath.prefix(2) == [0, 1])
    }
}
