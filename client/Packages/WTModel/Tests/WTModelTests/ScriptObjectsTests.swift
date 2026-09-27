import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// DOC-026/DOC-027's model half: the object model the AppleScript dictionary and the App Intents
/// share with JavaScript (`ScriptObjects`).
@Suite struct ScriptObjectsTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)

    static func core() throws -> DocumentCore {
        try DocumentCreation.newDocument(from: .builtIn, replica: 0xC, now: now)
    }

    static func perform(_ command: any Command, on core: inout DocumentCore) throws -> Wiretuner_Doc_V1_Change? {
        try core.perform(command, recording: DocumentCore.Recording(limit: 10, now: now))?.change
    }

    @Test func pagesReadAndSetTheirSizeAndMaster() throws {
        var core = try Self.core()
        let page = try #require(ScriptObjects.list("pages", in: core.state)?.first)
        let size = try #require(ScriptObjects.get(page, "size", in: core.state) as? [String: Any])
        #expect(size["width"] as? Double == 612 && size["height"] as? Double == 792)
        _ = try Self.perform(ScriptObjects.setting(page, "size", to: [500, 400], in: core.state).command, on: &core)
        #expect(PageList(core.state).pages[0].geometry.size == Size(width: 500, height: 400))
        _ = try Self.perform(ScriptObjects.setting(page, "size", to: ["width": 300, "height": 200], in: core.state).command, on: &core)
        #expect(PageList(core.state).pages[0].geometry.size == Size(width: 300, height: 200))
        #expect(throws: ScriptObjects.InvalidValue.self) { try ScriptObjects.setting(page, "size", to: [0, 10], in: core.state) }
        #expect(throws: ScriptObjects.InvalidValue.self) { try ScriptObjects.setting(page, "size", to: "big", in: core.state) }
        // Master: apply, read, release.
        _ = try Self.perform(NewMasterPage(from: page, name: "A"), on: &core)
        let master = try #require(ScriptObjects.list("masterPages", in: core.state)?.first)
        #expect((ScriptObjects.get(master, "size", in: core.state) as? [String: Any])?["width"] as? Double == 300)
        _ = try Self.perform(ScriptObjects.setting(page, "master", to: ScriptObjects.string(master), in: core.state).command, on: &core)
        #expect(ScriptObjects.get(page, "master", in: core.state) as? OpID == master)
        _ = try Self.perform(ScriptObjects.setting(page, "master", to: nil, in: core.state).command, on: &core)
        #expect(ScriptObjects.get(page, "master", in: core.state) == nil)
        #expect(throws: ScriptObjects.InvalidValue.self) { try ScriptObjects.setting(page, "master", to: 12, in: core.state) }
        #expect(throws: ScriptObjects.ReadOnly.self) { try ScriptObjects.setting(page, "bounds", to: nil, in: core.state) }
    }

    @Test func addPagesValidatesAndAdds() throws {
        var core = try Self.core()
        _ = try Self.perform(ScriptObjects.addPages(count: 2, size: Size(width: 200, height: 100), orientation: .portrait), on: &core)
        let pages = PageList(core.state).pages
        #expect(pages.count == 3 && pages[2].geometry.size == Size(width: 100, height: 200))
        _ = try Self.perform(ScriptObjects.addPages(count: 1, size: Size(width: 200, height: 100)), on: &core)
        #expect(PageList(core.state).pages[3].geometry.size == Size(width: 200, height: 100))
        #expect(throws: ScriptObjects.InvalidValue(property: "count")) { try ScriptObjects.addPages(count: 0) }
        #expect(throws: ScriptObjects.InvalidValue(property: "size")) { try ScriptObjects.addPages(count: 1, size: Size(width: -1, height: 5)) }
    }

    @Test func findAndReplaceCountsAndReplacesEveryMatch() throws {
        var core = try Self.core()
        _ = try Self.perform(CreateTextBlock(.point(Point(x: 100, y: 100)), text: "Sale sale SALE"), on: &core)
        #expect(ScriptObjects.findAndReplace("", with: "x", in: core.state) == nil)
        #expect(ScriptObjects.findAndReplace("nothing", with: "x", in: core.state) == nil)
        let matchCase = try #require(ScriptObjects.findAndReplace("sale", with: "deal", matchCase: true, in: core.state))
        #expect(matchCase.count == 1)
        let all = try #require(ScriptObjects.findAndReplace("sale", with: "deal", in: core.state))
        #expect(all.count == 3)
        _ = try Self.perform(all.command, on: &core)
        let text = try #require(ScriptObjects.list("objects", in: core.state)?.first)
        #expect(ScriptObjects.get(text, "text", in: core.state) as? String == "deal deal deal")
    }

    @Test func theReportListsPagesLayersObjectsSwatchesAndStyles() throws {
        var core = try Self.core()
        _ = try Self.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10)), on: &core)
        _ = try Self.perform(RenamePage(PageList(core.state).pages[0].id, to: "Cover", in: core.state), on: &core)
        _ = try Self.perform(ScriptObjects.addPages(count: 1, size: Size(width: 100.5, height: 50)), on: &core)
        let report = ScriptObjects.report(name: "Brochure", state: core.state)
        #expect(report.hasPrefix("Document: Brochure\n"))
        #expect(report.contains("Pages: 2") && report.contains("  Cover: 612 × 792 pt") && report.contains("100.50 × 50 pt"))
        #expect(report.contains("Objects: 1") && report.contains("  rectangle: 1") && report.contains("Layers: 1"))
        #expect(report.contains("Swatches: ") && report.contains("Styles: "))
    }

    @Test func idsKindsCollectionsAndErrorsRead() throws {
        var core = try Self.core()
        #expect(ScriptObjects.id(ScriptObjects.string(OpID(counter: 4, replica: 9))) == OpID(counter: 4, replica: 9))
        #expect(ScriptObjects.id("nope") == nil && ScriptObjects.list("nope", in: core.state) == nil)
        #expect(ScriptObjects.list("selection", in: core.state, selection: [OpID(counter: 999_999, replica: 77)]) == [])
        let change = try Self.perform(CreateShape(.ellipse, size: Size(width: 10, height: 10)), on: &core)
        let ellipse = try #require(change?.createdObjects.first)
        let layer = try #require(ScriptObjects.list("layers", in: core.state)?.first)
        #expect(ScriptObjects.objects(in: core.state, under: layer) == [ellipse])
        #expect(ScriptObjects.get(ellipse, "layer", in: core.state) as? OpID == layer)
        #expect(ScriptObjects.get(.zero, "name", in: core.state) == nil)
        let style = try #require(ScriptObjects.list("styles", in: core.state)?.first)
        #expect((ScriptObjects.get(style, "name", in: core.state) as? String)?.isEmpty == false)
        _ = try Self.perform(ScriptObjects.setting(ellipse, "layer", to: layer, in: core.state).command, on: &core)
        let moved = try ScriptObjects.calling(ellipse, "moveTo", layer, in: core.state)
        #expect(moved.command is MoveObjectsToLayer)
        #expect(ScriptObjects.ReadOnly(property: "fill", kind: "path").description.contains("cannot be set"))
        #expect(ScriptObjects.Unsupported(call: "x").description.contains("not available"))
        #expect(ScriptObjects.InvalidValue(property: "size").description.contains("size"))
        #expect(ScriptObjects.format(2) == "2" && ScriptObjects.format(2.5) == "2.50")
    }

    @Test func objectSetsCreationsAndTheirErrors() throws {
        var core = try Self.core()
        let change = try Self.perform(ScriptObjects.creating("rectangle", ["x": 10, "y": 10, "width": 20, "height": 20]), on: &core)
        let rect = try #require(change?.createdObjects.first)
        _ = try Self.perform(ScriptObjects.setting(rect, "url", to: "https://example.com", in: core.state).command, on: &core)
        _ = try Self.perform(ScriptObjects.setting(rect, "notes", to: "n", in: core.state).command, on: &core)
        #expect(ScriptObjects.get(rect, "url", in: core.state) as? String == "https://example.com")
        #expect(ScriptObjects.get(rect, "notes", in: core.state) as? String == "n")
        #expect(throws: DataEditError.self) { try ScriptObjects.setting(rect, "position", to: "here", in: core.state) }
        #expect(throws: DataEditError.self) { try ScriptObjects.setting(rect, "layer", to: "not-an-id", in: core.state) }
        #expect(throws: DataEditError.self) { try ScriptObjects.calling(rect, "moveTo", "x", in: core.state) }
        let page = try #require(ScriptObjects.list("pages", in: core.state)?.first)
        #expect(throws: ScriptObjects.InvalidValue.self) { try ScriptObjects.setting(page, "master", to: "bad", in: core.state) }
        for kind in ["ellipse", "line", "text", "barcode"] {
            #expect(try Self.perform(ScriptObjects.creating(kind, ["text": "t", "value": "v"]), on: &core) != nil, "\(kind)")
        }
        #expect(throws: ScriptUnavailable.self) { try ScriptObjects.creating("image", [:]) }
        #expect(ScriptObjects.report(name: "Empty", state: EngineState()).contains("Pages: 0"))
    }
}
