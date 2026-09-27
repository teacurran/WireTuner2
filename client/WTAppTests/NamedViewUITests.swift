import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// BASIC-015's app half: the New View sheet's write, menu:View[Custom], Previous, the Edit Views
/// sheet and the magnification pop-up.
@Suite(.serialized) @MainActor struct NamedViewUITests {
    static func names(_ world: GlueWorld) -> [String] { NamedViews.list(world.state).map(\.name) }

    @Test func theModesAndTargetsRoundTrip() {
        for mode in ViewMode.allCases {
            #expect(NamedViewFeatures.viewMode(NamedViewFeatures.drawingMode(mode)) == mode)
        }
        #expect(NamedViewFeatures.viewMode(.unspecified) == .preview)
        let viewport = Viewport(scrollOrigin: Point(x: 100, y: 50), zoom: 2, size: Size(width: 400, height: 300))
        #expect(NamedViewFeatures.visibleRect(viewport) == Rect(x: 100, y: 50, width: 200, height: 150))
        let target = NamedViewFeatures.target(of: viewport, mode: .keyline)
        #expect(abs(target.magnification - 2) < 1e-9 && target.scrollOrigin.distance(to: Point(x: 100, y: 50)) < 1e-9 && target.mode == .keyline)
        var turned = viewport
        turned.rotationDegrees = 30
        let recalled = NamedViewFeatures.viewport(for: target, like: turned)
        #expect(recalled.zoom == 2 && recalled.scrollOrigin == target.scrollOrigin && recalled.rotationDegrees == 30, "the rotation is the window's")
    }

    @Test func theCustomSubmenuRecallsViewsAndPreviousSwapsTheLastTwo() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let window = world.window
        let features = NamedViewFeatures(window: { [weak window] in window }, sheets: world.sheets())
        let rebuilt = TestBox(0)
        features.onMenuChange = { rebuilt.value += 1 }
        features.install(commands: world.commands)
        features.attach(window)
        let previous = StandardCommands.ID.customPrevious
        #expect(world.commands.validate(previous) == .disabled(NamedViewFeatures.needsTwo))
        // Two views: at 200% and at 50% in Keyline.
        window.zoom(toPercent: 200)
        _ = await window.createNamedView("  Logo detail ", from: window.viewport).value
        window.zoom(toPercent: 50)
        window.setViewMode(.keyline)
        _ = await window.createNamedView("", from: window.viewport).value
        await world.document.settle()
        #expect(Self.names(world) == ["Logo detail", "View 2"])
        #expect(features.listed == ["Logo detail", "View 2"] && rebuilt.value > 0)
        #expect(window.statusBar.namedViews == ["Logo detail", "View 2"] && window.statusBar.magnificationItems.suffix(2) == ["Logo detail", "View 2"])
        #expect(world.commands.command(NamedViewFeatures.id(0))?.title == "Logo detail")
        // Recall from the menu, then from the magnification pop-up.
        window.setViewMode(.preview)
        #expect(world.commands.perform(NamedViewFeatures.id(0)))
        #expect(abs(window.viewport.zoom - 2) < 1e-6 && window.viewMode == .preview)
        window.statusBar.onMagnification?("View 2")
        #expect(abs(window.viewport.zoom - 0.5) < 1e-6 && window.viewMode == .keyline)
        window.statusBar.onMagnification?("400%")
        #expect(abs(window.viewport.zoom - 4) < 1e-6, "a magnification is still one")
        // Previous swaps between the two.
        #expect(world.commands.validate(previous) == .enabled)
        #expect(world.commands.perform(previous))
        #expect(abs(window.viewport.zoom - 2) < 1e-6)
        #expect(features.previous(in: window)?.name == "View 2")
        // A deleted view drops out of the menu and the pair.
        let second = NamedViews.list(world.state)[1].id
        _ = await world.document.perform(DeleteCustomView([second])).value
        await world.document.settle()
        #expect(features.listed == ["Logo detail"] && world.commands.command(NamedViewFeatures.id(1)) == nil)
        #expect(features.previous(in: window) == nil && world.commands.validate(previous) == .disabled(NamedViewFeatures.needsTwo))
        // Becoming main refreshes; without a window everything is disabled.
        window.onBecomeMain?(window)
        let orphan = NamedViewFeatures(window: { nil })
        orphan.install(commands: CommandRegistry())
        #expect(orphan.commands().allSatisfy { $0.validation() == .disabled(NamedViewFeatures.noDocument) })
        #expect(orphan.viewCommand(0, name: "X").validation() == .disabled(NamedViewFeatures.noDocument))
        for command in orphan.commands() + [orphan.viewCommand(0, name: "X"), features.viewCommand(7, name: "Gone")] {
            if case .perform(let run) = command.action { run() }
        }
        orphan.refreshMenu()
        let typed = TestBox<[String]>([])
        features.magnification("Logo detail", in: nil) { typed.value.append($0) }
        features.viewsDidChange(in: nil)
        #expect(typed.value == ["Logo detail"])
    }

    @Test func theNewViewSheetSavesTheView() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let window = world.window
        let sheet = try #require(window.presentNamedViewSheet(target: window.viewport))
        #expect(sheet.identifier == NamedViewSheet.identifier)
        window.endNamedViewSheet()
        Render.view(NamedViewSheetView(summary: NamedViewSheet.summary(of: window.viewport)) { _ in })
        #expect(NamedViewSheet.sharedNote.contains("saved with the document"))
    }

    @Test func theEditViewsSheetRenamesRedefinesDeletesAndReorders() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let window = world.window
        let features = NamedViewFeatures(window: { [weak window] in window }, sheets: world.sheets())
        features.install(commands: world.commands)
        features.attach(window)
        for name in ["A", "B", "C"] { _ = await window.createNamedView(name, from: window.viewport).value }
        await world.document.settle()
        #expect(world.commands.perform(StandardCommands.ID.customEdit))
        let model = try #require(features.editing)
        #expect(features.showEditViews(window) === model, "one sheet at a time")
        #expect(world.presented.value.last?.identifier?.rawValue == NamedViewFeatures.sheet)
        #expect(model.views.map(\.name) == ["A", "B", "C"])
        Render.view(EditViewsSheet(model: model))
        let a = model.views[0]
        Render.view(EditViewRow(view: a, model: model))
        EditViewRow.commit(a, model, .constant("Alpha"))()
        await world.document.settle()
        #expect(model.views[0].name == "Alpha" && world.document.undoTitle == "Undo Rename View")
        #expect(model.rename(a.id, to: "Alpha") == nil, "unchanged")
        // Nothing selected: the buttons do nothing.
        #expect(model.redefine() == nil && model.delete() == nil)
        model.selection = model.views[1].id
        window.zoom(toPercent: 800)
        EditViewsSheet.redefine(model)()
        await world.document.settle()
        #expect(abs(model.views[1].target.magnification - 8) < 1e-6 && world.document.undoTitle == "Undo Redefine View")
        // C to the top.
        EditViewsSheet.mover(model)(IndexSet(integer: 2), 0)
        await world.document.settle()
        #expect(model.views.map(\.name) == ["C", "Alpha", "B"])
        #expect(model.move(from: IndexSet(integer: 0), to: 1) == nil && model.move(from: IndexSet(integer: 9), to: 0) == nil)
        _ = await model.move(from: IndexSet(integer: 0), to: 3)?.value
        #expect(model.views.map(\.name) == ["Alpha", "B", "C"])
        model.selection = model.views[1].id
        EditViewsSheet.delete(model)()
        await world.document.settle()
        #expect(model.views.map(\.name) == ["Alpha", "C"] && model.selection == nil)
        // A view deleted elsewhere leaves the selection.
        model.selection = model.views[1].id
        _ = await world.document.receiveRemote(DeleteCustomView([model.views[1].id]))
        #expect(model.selection == nil)
        model.close()
        #expect(features.editing == nil)
    }
}
