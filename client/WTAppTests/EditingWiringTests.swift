import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTRender
@testable import WireTuner

/// This batch's wiring in the app: the Align, Transform and Find & Replace panels in the Window
/// menu's slots, the Text menu's effect items, the path tools and menu:Modify[Split], and a
/// double-click on a transformation tool bringing the Transform panel forward on its tab.
@Suite(.serialized) @MainActor struct EditingWiringTests {
    @Test func theBatchIsWiredIntoTheApp() async throws {
        let suite = TestDefaults()
        defer { suite.remove() }
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = try #require(delegate.activeDocumentWindow)
        defer { window.close() }
        #expect(delegate.panels.descriptor(for: "align") != nil && delegate.panels.descriptor(for: "findReplace") != nil)
        #expect(delegate.commands.command(TextFeatures.ID.effect(.shadow)) != nil)
        #expect(!(delegate.tools.makeTool(KnifeTool.id) is UnimplementedTool))
        // A double-click on the Rotate tool opens the Transform panel on its tab.
        delegate.toolPalette.showOptions("rotate")
        #expect(delegate.editingPanels.transform.model.tab == .rotate && delegate.layout.isVisible("transform"))
        // Split acts on the front window's selection.
        let document = window.documentHandle
        let square = try #require(await document.addPath([Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 100), Point(x: 0, y: 100)], closed: true))
        let contour = try #require(document.path(square)?.contours[0])
        window.selection.model.set(Selection([square]).applying([square], sub: [square: .points([PointReference(node: NodeID(square.opID), contour: contour.id, point: contour.drawn[2].id)])], mode: .replace))
        let split = try #require(delegate.commands.command(ContextMenuCatalog.ID.split))
        #expect(split.validation() == .enabled)
        if case .perform(let run) = split.action { run() }
        await document.settle()
        #expect(document.path(square)?.contours[0].closed == false)
    }
}
