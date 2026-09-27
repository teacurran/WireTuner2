import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel

/// DOC-012's rest: the pages a master page's tab reads, and the page commands the Document panel,
/// guides and the Page tool send with the master's id writing the master.
@Suite struct MasterCanvasPagesTests {
    @Test func theMasterIsTheOnePageAtTheOrigin() throws {
        var a = Replica(0xD12)
        try a.perform(AddPages(count: 1))
        let pages = PageList(a.state).pages
        try a.perform(SetBleed([pages[0].id], to: 9))
        try a.perform(NewMasterPage(from: pages[0].id, name: "Master A"))
        let list = PageList(a.state)
        let master = try #require(list.masters.first)
        let canvas = try #require(list.onMasterCanvas(master.id))
        #expect(canvas.pages.count == 1 && canvas.isMasterCanvas && !list.isMasterCanvas)
        let page = canvas.pages[0]
        #expect(page.id == master.id && page.name == "Master A" && page.number == 1 && !page.isChild && !page.isSynthesized)
        #expect(page.rect == master.rect && page.origin == .zero && page.bleed == 9 && page.geometry == master.geometry)
        #expect(page.zeroPoint == Point(x: 0, y: master.geometry.height))
        #expect(canvas.masters == list.masters && canvas.settings == list.settings)
        #expect(canvas[master.id] == page && canvas.page(containing: Point(x: 10, y: 10))?.id == master.id)
        #expect(list.onMasterCanvas(pages[1].id) == nil)
    }

    @Test func pageCommandsGivenTheMasterWriteTheMaster() throws {
        var a = Replica(0xD13)
        try a.perform(AddPages(count: 1))
        let first = PageList(a.state).pages[0].id
        try a.perform(NewMasterPage(from: first))
        let master = try #require(PageList(a.state).masters.first).id
        try a.perform(ApplyMasterPage(master, to: [first]))
        // The Document panel: size, orientation, bleed.
        try a.perform(SetPageGeometry([master], to: PageGeometry(width: 400, height: 600)))
        try a.perform(SetPageOrientation([master], to: .landscape))
        try a.perform(SetBleed([master], to: 18))
        // Guides from the rulers.
        try a.perform(AddGuides(on: [master], axis: .vertical, at: [72]))
        let canvas = try #require(PageList(a.state).onMasterCanvas(master))
        #expect(canvas.pages[0].geometry.width == 600 && canvas.pages[0].geometry.height == 400 && canvas.pages[0].bleed == 18)
        #expect(canvas.pages[0].guides.map(\.position) == [72])
        // The child follows.
        let child = try #require(PageList(a.state)[first])
        #expect(child.geometry.width == 600 && child.bleed == 18 && child.guides.isEmpty)
    }
}
