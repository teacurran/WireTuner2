import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTText
@testable import WireTuner

/// TYPE-017's text-on-path items for TYPE-041's commands (menu:Text[Attach to Path], *Flow Inside
/// Path*, *Detach from Path* and the Object panel's buttons) and the Text tool editing text on a
/// path: its layout, carets and hit tests follow the curve.
@Suite(.serialized) @MainActor struct TextOnPathMenuTests {
    /// A text block and an open straight path under it, both on the page.
    func pair(_ fixture: TextToolTests.Fixture) async throws -> (text: OpID, path: OpID) {
        let text = try #require(await fixture.document.addText("Hello path", at: Point(x: 40, y: 40)))
        let path = try #require(await fixture.document.addPath([Point(x: 20, y: 200), Point(x: 380, y: 200)]))
        return (text, path.opID)
    }

    @Test func attachFlowAndDetachAreCommandsWithTheirRefusals() async throws {
        let fixture = TextToolTests.Fixture()
        let (text, path) = try await pair(fixture)
        let editing = fixture.editing
        let registry = CommandRegistry()
        TextOnPathMenu.install(into: registry) { editing }
        let ids = ContextMenuCatalog.ID.self
        #expect(registry.command(ids.attachToPath)?.defaultKey == TextOnPathMenu.key)
        #expect(registry.command(ids.attachToPath)?.validation().reason == TextOnPathMenu.pairNeeded)
        #expect(registry.command(ids.detachFromPath)?.validation().reason == TextOnPathMenu.notOnPath)
        fixture.controller.model.set(Selection([SelectionID(text), SelectionID(path)]))
        #expect(registry.command(ids.attachToPath)?.validation() == .enabled)
        #expect(registry.command(ids.flowInsidePath)?.validation().reason == TextOnPathMenu.closedNeeded)
        #expect(TextOnPathMenu.attach(fixture.editing, mode: .inside) == nil)
        #expect(registry.perform(ids.attachToPath))
        await fixture.settle()
        for _ in 0..<200 where fixture.controller.selection.ids != [SelectionID(text)] { await Task.yield() }
        #expect(fixture.document.undoTitle == "Undo Attach to path" && fixture.controller.selection.ids == [SelectionID(text)])
        #expect(TextOnPathMenu.isOnPath(text, in: fixture.document.state) && Objects.parent(of: path, in: fixture.document.state) == text)
        // Detach from the text or from its path.
        #expect(TextOnPathMenu.detachTargets(fixture.editing) == [text])
        fixture.controller.model.set(Selection([SelectionID(path)]))
        #expect(TextOnPathMenu.detachTargets(fixture.editing) == [path])
        // A text on a path and another path: detach first.
        let other = try #require(await fixture.document.addPath([Point(x: 20, y: 250), Point(x: 380, y: 250)]))
        fixture.controller.model.set(Selection([SelectionID(text), other]))
        #expect(TextOnPathMenu.attachRefusal(fixture.editing, mode: .along) == TextOnPathMenu.alreadyOnPath)
        fixture.controller.model.set(Selection([SelectionID(text)]))
        #expect(registry.perform(ids.detachFromPath))
        await fixture.settle()
        #expect(fixture.document.undoTitle == "Undo Detach from path" && !TextOnPathMenu.isOnPath(text, in: fixture.document.state))
        #expect(TextOnPathMenu.detach(fixture.editing) == nil)
        // Flow inside a closed path.
        let closed = try #require(await fixture.document.addPath([Point(x: 200, y: 20), Point(x: 380, y: 20), Point(x: 380, y: 160), Point(x: 200, y: 160)], closed: true))
        fixture.controller.model.set(Selection([closed, SelectionID(text)]))
        #expect(registry.perform(ids.flowInsidePath))
        await fixture.settle()
        #expect(fixture.document.undoTitle == "Undo Flow inside path" && fixture.document.state.props(text).text.onPath.mode == .inside)
        // A group is neither text nor a path: nothing to detach.
        fixture.controller.model.set(Selection([other]))
        #expect(TextOnPathMenu.detachTargets(fixture.editing).isEmpty)
        #expect(!TextOnPathMenu.isOnPath(other.opID, in: fixture.document.state))
        // A rectangle is neither text nor a path; a failing attach selects nothing.
        let box = try #require(await fixture.document.addRectangles([Rect(x: 300, y: 250, width: 10, height: 10)]).first)
        fixture.controller.model.set(Selection([box]))
        #expect(TextOnPathMenu.detachTargets(fixture.editing).isEmpty)
        await TextOnPathMenu.perform(WTModel.AttachTextToPath(text: box.opID, path: box.opID), text: box.opID, fixture.editing).value
        #expect(fixture.controller.selection.ids == [box])
        // Without a window nothing is enabled.
        #expect(TextOnPathMenu.commands { nil }.allSatisfy { !$0.validation().isEnabled })
    }

    @Test func theObjectPanelOffersTheButtonsForThePairAndForTextOnAPath() async throws {
        let fixture = TextToolTests.Fixture()
        let (text, path) = try await pair(fixture)
        let editing = fixture.editing
        let section = TextOnPathMenu.section { editing }
        let model = ObjectPanelModel(document: fixture.document, selection: Selection([]))
        #expect(section.make(model) == nil, "nothing selected")
        #expect(TextOnPathMenu.section { nil }.make(model) == nil)
        fixture.controller.model.set(Selection([SelectionID(text), SelectionID(path)]))
        #expect(section.make(model) != nil && section.applies(to: [.text, .path]))
        Render.view(TextOnPathButtons(target: { editing }, attach: true, detach: false, attachEnabled: true, flowEnabled: false))
        TextOnPathButtons.attaching({ editing }, mode: .along)()
        await fixture.settle()
        #expect(TextOnPathMenu.isOnPath(text, in: fixture.document.state))
        fixture.controller.model.set(Selection([SelectionID(text)]))
        #expect(section.make(model) != nil)
        Render.view(TextOnPathButtons(target: { editing }, attach: false, detach: true, attachEnabled: false, flowEnabled: false))
        TextOnPathButtons.detaching({ editing })()
        await fixture.settle()
        #expect(!TextOnPathMenu.isOnPath(text, in: fixture.document.state))
        TextOnPathButtons.attaching({ nil }, mode: .along)()
        TextOnPathButtons.detaching({ nil })()
    }

    @Test func theTextToolEditsTextOnAPathAlongTheCurve() async throws {
        let fixture = TextToolTests.Fixture()
        let (text, path) = try await pair(fixture)
        _ = await fixture.document.perform(WTModel.AttachTextToPath(text: text, path: path)).value
        await fixture.settle()
        // The document lays the text out along the path, as the canvas draws it.
        let layout = try #require(fixture.document.textLayout(for: text))
        guard case .path? = layout.containers.first else { Issue.record("not laid out on the path"); return }
        let frame = TextFrames.frame(of: layout).applying(Objects.pasteboardTransform(of: text, in: fixture.document.state))
        #expect(frame.minY < 200 && frame.maxY >= 200 && frame.minX <= 20 && frame.maxX >= 380)
        // A click on the curve edits the text; the caret sits on the path.
        fixture.click(30, 196)
        let session = try #require(fixture.session)
        #expect(session.node == text)
        let caret = try #require(session.caret)
        #expect(abs(caret.bottom.y - 200) < 8 && caret.top.y < caret.bottom.y)
        #expect(session.contains(Point(x: 100, y: 195)) && !session.contains(Point(x: 100, y: 20)))
        #expect(session.offset(at: Point(x: 380, y: 196)) == fixture.document.string(text)?.unicodeScalars.count)
        // A block's frame starts at its origin.
        let block = try #require(await fixture.document.addText("Block", at: Point(x: 40, y: 260)))
        let blockFrame = TextFrames.frame(of: try #require(fixture.document.textLayout(for: block)))
        #expect(blockFrame.minX == 0 && blockFrame.minY == 0 && blockFrame.width > 1)
    }
}
