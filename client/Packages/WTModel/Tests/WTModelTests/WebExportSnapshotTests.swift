import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender
import WTText

/// WEB-005, WEB-023, WEB-018: the navigation facts, page numbers, text-range links and animation
/// autoplay the export snapshot carries.
@Suite struct WebExportSnapshotTests {
    @Test @MainActor func linksPageLinksAndTextRangesReachTheScene() throws {
        var a = Replica(0xA)
        let layer = try NavigationFixture.layer(&a)
        let pages = try NavigationFixture.pages(&a)
        let rect = try NavigationFixture.rect(&a, on: layer)
        let next = try NavigationFixture.rect(&a, on: layer, x: 40)
        try a.perform(SetLink([rect], url: "shop.example.com"))
        try a.perform(SetLinkAlt([rect], alt: "Order form"))
        try a.perform(SetLinkTarget([rect], target: .newTab))
        try a.perform(SetGoToPage([next], page: pages[1]))
        let text = try a.perform(CreateTextBlock(.point(Point(x: 10, y: 50)), text: "Visit our shop today", layer: layer))!.createdObjects[0]
        let node = TextFixture.text(a, text)
        try a.perform(SetTextLink(node: text, from: node.anchor(at: 6), to: node.anchor(at: 14), url: "https://shop.example"))
        let request = ExportSnapshot.Request(name: "Links", pages: [ExportSnapshot.Page(bounds: Rect(x: 0, y: 0, width: 300, height: 300)),
                                                                    ExportSnapshot.Page(bounds: Rect(x: 400, y: 0, width: 300, height: 300))],
                                             scope: .pages([0, 1]))
        let snapshot = ExportSnapshotTests.capture(a.state, request)
        let scene = snapshot.scene
        #expect(scene.pages.map(\.number) == [1, 2])
        let info = try #require(scene.nodes[NodeID(rect)])
        #expect(info.url == "shop.example.com" && info.linkAlt == "Order form" && info.linkTarget == .newTab && info.pageLink == nil)
        #expect(scene.nodes[NodeID(next)]?.pageLink == 2)
        // Text-range links are laid out one rectangle per line on the main actor.
        let fonts = DocumentFontIndex(state: a.state)
        let links = ExportSnapshot.textLinks(a.state, engine: fonts.layoutEngine)
        let ranges = try #require(links[NodeID(text)])
        #expect(ranges.count == 1 && ranges[0].url == "https://shop.example" && ranges[0].rects.count == 1)
        let rectangle = ranges[0].rects[0]
        #expect(rectangle.minX > 10 && rectangle.width > 10 && rectangle.minY >= 40)
        // Deleting the block leaves its links out.
        try a.perform(DeleteNodes([text]))
        #expect(ExportSnapshot.textLinks(a.state, engine: fonts.layoutEngine).isEmpty)
    }

    @Test func theAnimationCarriesAutoplay() throws {
        var a = Replica(0xA)
        _ = try LayerFixture.layers(["One", "Two"], on: &a)
        try a.perform(SetAnimationSettings(source: .layers, autoplay: false))
        let request = ExportSnapshot.Request(name: "Anim", pages: [ExportSnapshot.Page(bounds: Rect(x: 0, y: 0, width: 100, height: 100))], scope: .pages([0]),
                                             animation: true)
        let animation = try #require(ExportSnapshotTests.capture(a.state, request).scene.animation)
        #expect(!animation.autoplay)
    }
}
