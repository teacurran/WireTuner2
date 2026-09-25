import AppKit
import SwiftUI
import Testing
@testable import WireTuner

/// The Help panel (BASIC-007): search over the bundled guide, the page view, *What's here* and
/// *What's New*, and *Help for <panel>*.
@Suite(.serialized) @MainActor struct HelpPanelTests {
    @Test func searchingBezigonListsThePenAndBezigonPageFirst() {
        let results = HelpCatalog.search("bezigon")
        #expect(results.first?.slug == "pen-bezigon")
        #expect(HelpCatalog.search("   ").isEmpty && HelpCatalog.search("zzqqxx").isEmpty)
        #expect(HelpCatalog.search("text editor").first.map { ["editing-text", "creating-text"].contains($0.slug) } == true)
        #expect(HelpCatalog.page("panels")?.title == "Using panels" && HelpCatalog.page("nope") == nil)
        #expect(HelpCatalog.pages.count > 100 && HelpCatalog.contents.reduce(0) { $0 + $1.pages.count } == HelpCatalog.pages.count)
        let page = HelpPage(slug: "x", title: "A <b> & c", group: "", summary: "s", headings: [], keywords: ["alpha"])
        let html = HelpCatalog.html(page)
        #expect(html.contains("A &lt;b&gt; &amp; c") && !html.contains("On this page"))
        #expect(HelpCatalog.html(HelpCatalog.pages[0]).contains("<h1>"))
        #expect(HelpCatalog.search("alpha", in: [page]) == [page])
        #expect(HelpCatalog.bookURL("pen-bezigon", bundle: Bundle(for: HelpBundleMarker.self)) == nil)
    }

    @Test func theBrowserOpensPagesFollowsHelpForAndShowsWhatsNew() throws {
        let model = HelpBrowserModel()
        #expect(model.mode == .contents && model.page == nil)
        model.query = "bezigon"
        #expect(model.mode == .results && model.results.first?.slug == "pen-bezigon")
        model.open("pen-bezigon")
        #expect(model.page?.slug == "pen-bezigon")
        model.showWhatsNew()
        #expect(model.mode == .whatsNew && !HelpCatalog.whatsNew.isEmpty)
        model.showContents()
        #expect(model.mode == .contents && model.query.isEmpty)
        let help = HelpPanelModel()
        help.show(slug: "layers", topic: "Layers")
        model.follow(help)
        #expect(model.page?.slug == "layers")
        help.show(slug: "not-a-page", topic: "x")
        model.follow(help)
        #expect(model.page?.slug == "layers")
        model.setHover("Pen", slug: "pen-bezigon")
        #expect(model.hover?.slug == "pen-bezigon")
        // The views render in each mode.
        for mode in 0..<4 {
            switch mode {
            case 0: model.showContents()
            case 1: model.query = "pen"
            case 2: model.open("pen-bezigon")
            default: model.showWhatsNew()
            }
            PanelRendering.host(HelpBrowserView(model: model, help: help))
        }
        HelpBrowserView.opening("charts", model)()
        #expect(model.page?.slug == "charts")
        help.show(slug: "panels", topic: "Help")
        HelpBrowserView.following(model, help)(nil, "panels")
        #expect(model.page?.slug == "panels")
        let view = HelpPageView(page: try #require(HelpCatalog.page("panels")))
        PanelRendering.host(view)
        let descriptor = HelpFeatures.descriptor(help: help, browser: model)
        #expect(descriptor.id == "help" && descriptor.helpSlug == "panels")
        _ = descriptor.makeView()
    }

    @Test func hoveringATooNamesItInThePanelOffline() async throws {
        let environment = TestEnvironment()
        let model = HelpBrowserModel()
        let hover = HelpHover(tools: environment.tools, panels: environment.panels, model: model)
        let pen = try #require(environment.tools.descriptors.first { $0.id.rawValue == "pen" })
        #expect(hover.resolve(pen.commandID.rawValue)?.slug == pen.helpSlug)
        #expect(hover.resolve(pen.commandID.rawValue + ".flyout")?.title == pen.title)
        #expect(hover.resolve("panel.object")?.slug == "object-panel")
        #expect(hover.resolve("panel.nothing") == nil && hover.resolve("unknown") == nil)
        // A button carrying the Pen's identifier, found through accessibility after the delay.
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 200, height: 200))
        defer { window.close() }
        let button = NSButton(title: "Pen", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 20, width: 80, height: 30)
        button.setAccessibilityIdentifier(pen.commandID.rawValue)
        window.contentView?.addSubview(button)
        #expect(hover.identify(at: NSPoint(x: 40, y: 35), in: window)?.slug == pen.helpSlug)
        #expect(hover.identify(at: NSPoint(x: 190, y: 190), in: window) == nil)
        hover.delay = .milliseconds(20)
        hover.pointerMoved(to: NSPoint(x: 40, y: 35), in: window)
        await hover.settle()
        #expect(model.hover?.title == pen.title)
        hover.pointerMoved(to: .zero, in: nil)
        hover.start()
        hover.start()
        hover.stop()
    }
}

/// A class of this test bundle (its bundle carries no Help Book).
final class HelpBundleMarker {}
