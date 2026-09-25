import AppKit
import Foundation
import SwiftUI
import Testing
import WTGeometry
import WTModel
import WTProto
@testable import WireTuner

/// The Output Area editor in the Object panel (PRINT-012) and the Halftones panel's angle dial
/// (PRINT-010).
@Suite(.serialized) @MainActor struct PrintEditorTests {
    // MARK: Output area editor

    @Test func theEditorShowsWhileTheToolIsActiveAndWritesTheArea() async throws {
        let world = PrintWorld()
        defer { world.close() }
        let selection = world.selection
        // No tool, or no area: the panel shows the selection.
        #expect(OutputAreaEditorModel.model(selection) == nil)
        selection.activeToolID = OutputAreaTool.id
        #expect(OutputAreaEditorModel.model(selection) == nil)
        #expect(OutputAreaEditorModel.model(nil) == nil)
        let registry = InspectorRegistry()
        OutputAreaEditor.register(into: registry)
        OutputAreaEditor.register(into: registry)
        #expect(registry.replacements.count == 1 && registry.replacement(for: selection) == nil)
        Render.view(ObjectPanelBody(selection: selection, registry: registry))

        // A collaborator defines an area: the editor appears with its values.
        let area = Rect(x: 100, y: 120, width: 144, height: 72)
        await world.document.receiveRemote(SetOutputArea(area))
        let model = try #require(OutputAreaEditorModel.model(selection))
        #expect(model.value(.x) == 100 && model.value(.y) == 120 && model.value(.width) == 144 && model.value(.height) == 72)
        #expect(registry.replacement(for: selection) != nil)
        Render.view(ObjectPanelBody(selection: selection, registry: registry))
        PanelRendering.host(OutputAreaEditor(model: model))

        // Typing W = 3.5in resizes the area: one change labelled "Resize output area".
        model.commit(.width)(252)
        await world.document.settle()
        #expect(world.area == Rect(x: 100, y: 120, width: 252, height: 72))
        #expect(world.document.model?.undoTitle == "Undo Resize output area")
        OutputAreaEditorModel.model(selection)!.commit(.height)(36)
        await world.document.settle()
        OutputAreaEditorModel.model(selection)!.commit(.x)(10)
        await world.document.settle()
        #expect(world.document.model?.undoTitle == "Undo Move output area")
        OutputAreaEditorModel.model(selection)!.commit(.y)(20)
        await world.document.settle()
        #expect(world.area == Rect(x: 10, y: 20, width: 252, height: 36))

        // Values that make no rectangle write nothing.
        let current = try #require(OutputAreaEditorModel.model(selection))
        #expect(current.command(.width, 0) == nil && current.command(.height, -1) == nil && current.command(.x, .nan) == nil)
        let changes = world.document.changeCount
        current.commit(.width)(0)
        await world.document.settle()
        #expect(world.document.changeCount == changes)

        // Without the window's editing the model performs on the document directly.
        selection.editing = nil
        OutputAreaEditorModel.model(selection)!.commit(.x)(30)
        await world.document.settle()
        #expect(world.area?.minX == 30)

        // Another tool: back to the selection.
        selection.activeToolID = "pointer"
        #expect(OutputAreaEditorModel.model(selection) == nil)
        let bare = OutputAreaEditorModel(document: DocumentHandle.memory(title: "Bare")) { _ in Issue.record("nothing to perform") }
        #expect(bare.value(.x) == nil && bare.command(.x, 1) == nil)
    }

    // MARK: Angle dial

    @Test func theDialFollowsThePointerSnapsWithShiftAndCommitsOnRelease() throws {
        let center = CGPoint(x: 20, y: 20)
        #expect(PointerDialControl.angle(of: CGPoint(x: 30, y: 20), around: center, snap: false) == 0)
        #expect(abs(PointerDialControl.angle(of: CGPoint(x: 20, y: 30), around: center, snap: false) - 90) < 1e-9)
        #expect(abs(PointerDialControl.angle(of: CGPoint(x: 20, y: 10), around: center, snap: false) - 270) < 1e-9)
        #expect(PointerDialControl.angle(of: CGPoint(x: 30, y: 20.5), around: center, snap: true) == 0)
        #expect(PointerDialControl.angle(of: CGPoint(x: 30, y: 12), around: center, snap: true) == 315)

        let control = PointerDialControl(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        var committed: [Double] = []
        control.onCommit = { committed.append($0) }
        #expect(control.intrinsicContentSize == NSSize(width: 44, height: 44) && !control.isFlipped && control.acceptsFirstMouse(for: nil))
        let window = TestWindow.make(control.frame, styleMask: [.borderless])
        window.contentView = control
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: control.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: flags, timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        control.isMixed = true
        control.mouseDown(with: event(.leftMouseDown, 20, 35))
        #expect(!control.isMixed && abs(control.angle - 90) < 1e-9 && committed.isEmpty)
        control.mouseDragged(with: event(.leftMouseDragged, 30, 29, .shift))
        #expect(control.angle == 45)
        control.mouseUp(with: event(.leftMouseUp, 30, 29, .shift))
        #expect(committed == [45])
        #expect(control.accessibilityRole() == .slider && control.accessibilityValue() as? String == "45°")
        #expect(control.accessibilityPerformIncrement() && committed.last == 60)
        #expect(control.accessibilityPerformDecrement() && control.step(-90) && committed.last == 315)
        control.isMixed = true
        #expect(control.accessibilityValue() as? String == "Mixed")
        let rep = try #require(control.bitmapImageRepForCachingDisplay(in: control.bounds))
        control.cacheDisplay(in: control.bounds, to: rep)
        control.isMixed = false
        control.cacheDisplay(in: control.bounds, to: rep)
        #expect(rep.colorAt(x: 20, y: 20) != nil)
        window.contentView = nil
    }

    @Test func theRepresentableShowsTheValueAndCommits() {
        var committed: [Double] = []
        let dial = PointerDial(angle: nil, identifier: "dial", commit: { committed.append($0) })
        let control = PointerDialControl()
        dial.update(control)
        #expect(control.isMixed && control.angle == 0)
        PointerDial(angle: 30, identifier: "dial", commit: { committed.append($0) }).update(control)
        #expect(!control.isMixed && control.angle == 30)
        control.finish()
        #expect(committed == [30])
        PanelRendering.host(VStack { dial; PointerDial(angle: 90, identifier: "dial2") { _ in } }, size: NSSize(width: 100, height: 100))
    }
}
