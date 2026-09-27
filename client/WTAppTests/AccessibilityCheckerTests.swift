import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// IO-033: the Check Accessibility panel.
@Suite(.serialized) @MainActor struct AccessibilityCheckerTests {
    @Test func rowsSelectDescribeAndUndoOneAtATime() async throws {
        let world = TypeWorld()
        defer { world.close() }
        AccessibilityCheckerFeatures.showsPanel = false
        ReadingOrderFeatures.showsPanel = false
        defer {
            AccessibilityCheckerFeatures.showsPanel = true
            ReadingOrderFeatures.showsPanel = true
        }
        let image = try await HandleWorld.place(in: world.document)
        let other = try await HandleWorld.place(in: world.document)
        // Onto the page, so the reading order lists them.
        let origin = world.document.pageList.pages[0].origin
        _ = await world.document.perform(TransformObjects([image, other], matrix: .translation(x: origin.x + 50, y: origin.y + 50), kind: .move)).value
        await world.settle()
        let command = AccessibilityCheckerFeatures.command { [weak window = world.window] in window }
        #expect(command.validation().isEnabled && !AccessibilityCheckerFeatures.command(window: { nil }).validation().isEnabled)
        if case .perform(let run) = command.action { run() }
        let model = try #require(AccessibilityCheckerFeatures.model(of: world.window))
        #expect(AccessibilityCheckerFeatures.show(on: world.window) === model)
        #expect(Set(model.report.missing.map(\.node)) == [image, other] && model.report.missingLanguage)
        #expect(!model.badges.isEmpty)
        world.window.canvas.drawOverlay(in: DrawingToolTests.bitmap())
        // A click selects the row's object.
        model.select(image)
        #expect(world.window.selection.selection.ids.map(\.opID) == [image])
        // Typing in the row describes the object: one change, `Describe "name"`.
        let before = world.document.changeCount
        #expect(model.describe(image) == nil, "nothing typed")
        AccessibilityCheckerView.draft(model, image).wrappedValue = "  A red kite  "
        #expect(AccessibilityCheckerView.draft(model, image).wrappedValue == "  A red kite  ")
        _ = await model.describe(image)?.value
        await world.settle()
        #expect(world.document.changeCount == before + 1 && world.document.undoTitle == "Undo Describe \"photo.png\"")
        #expect(world.state.accessibleDescription(of: image) == "A red kite" && !model.report.missing.contains { $0.node == image })
        _ = await model.markDecorative(other).value
        await world.settle()
        #expect(model.report.missing.isEmpty && world.document.changeCount == before + 2)
        _ = await world.document.undo().value
        await world.settle()
        model.refresh()
        #expect(model.report.missing.map(\.node) == [other], "undoes on its own")
        #expect(model.name(image) == "photo.png" && AccessibilityCheckerModel.ratio(4.46) == "4.5:1")
        // Arrange… opens the Reading Order panel.
        #expect(model.arrange() === ReadingOrderFeatures.model(of: world.window))
        ReadingOrderFeatures.close(world.window)
        PanelRendering.host(AccessibilityCheckerView(model: model, done: {}))
        AccessibilityCheckerFeatures.close(world.window)
        #expect(AccessibilityCheckerFeatures.model(of: world.window) == nil)
        AccessibilityCheckerFeatures.close(world.window)
        world.window.canvas.drawOverlay(in: DrawingToolTests.bitmap())
    }

    @Test func lowContrastTextIsListedWithItsRatio() async throws {
        let world = TypeWorld()
        defer { world.close() }
        AccessibilityCheckerFeatures.showsPanel = false
        defer { AccessibilityCheckerFeatures.showsPanel = true }
        let page = world.document.pageList.pages[0]
        var appearance = Appearances.standard
        appearance.fills = [Appearances.basicFill(red: 0.349, green: 0.349, blue: 0.349)]
        _ = await world.document.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 300, height: 100),
                                                     transform: .translation(x: page.origin.x + 40, y: page.origin.y + 40), appearance: appearance)).value
        let text = try #require(await world.document.addText("Grey on grey", frame: .area(Rect(x: page.origin.x + 50, y: page.origin.y + 50, width: 200, height: 40))))
        await world.settle()
        let model = AccessibilityCheckerFeatures.show(on: world.window)
        let row = try #require(model.report.lowContrast.first)
        #expect(row.node == text && row.ratio < 4.5)
        PanelRendering.host(AccessibilityCheckerView(model: model, done: {}))
        AccessibilityCheckerFeatures.close(world.window)
    }
}
