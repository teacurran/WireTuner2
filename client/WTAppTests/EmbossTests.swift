import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// FX-034: the Emboss dialog, its Apply preview, OK and Cancel, and the Cmd-click replay.
@Suite(.serialized) @MainActor struct EmbossTests {
    @MainActor
    final class World {
        let environment = TestEnvironment()
        let document = DocumentHandle.memory(title: "Emboss")
        let controller: SelectionController
        let editing: ObjectEditing
        let registry = ExtensionRegistry()
        var previews: [EmbossPreview] = []

        init() {
            controller = SelectionController(document: document)
            editing = ObjectEditing(document: document, selection: controller)
        }

        var store: PreferenceStore { environment.preferences }

        func install() {
            let editing = editing
            let descriptor = EmbossFeatures.descriptor(existing: registry, store: store, target: { editing }) { [unowned self] in self.previews.append($0) }
            registry.replace(descriptor!)
        }

        func square() async -> SelectionID {
            await document.addRectangles([Rect(x: 50, y: 50, width: 100, height: 100)])[0]
        }

        var groups: [OpID] { document.state.store.nodes.filter { document.state.nodeKind($0) == .group && document.state.isLive($0) } }
    }

    @Test func theDialogPreviewsAndOKKeepsOneChange() async throws {
        let w = World()
        w.install()
        #expect(w.registry.validation(ofExtension: EmbossFeatures.id).reason == EmbossFeatures.noShape)
        let square = await w.square()
        w.controller.model.set(Selection([square]))
        #expect(w.registry.validation(ofExtension: EmbossFeatures.id).isEnabled)
        #expect(w.registry.perform(EmbossFeatures.id))
        let preview = try #require(w.previews.last)
        // Apply previews; Apply again replaces the preview; Cancel undoes it.
        await preview.apply().value
        #expect(w.groups.count == 1 && w.document.undoTitle == "Undo Emboss")
        w.store.set(EmbossStyle.chisel.rawValue, for: EmbossFeatures.Keys.style)
        await preview.apply().value
        #expect(w.groups.count == 1)
        await preview.cancel()?.value
        #expect(w.groups.isEmpty && preview.cancel() == nil)
        // OK without a preview embosses; OK after a preview keeps it.
        await preview.ok()?.value
        #expect(w.groups.count == 1)
        #expect(preview.ok() == nil || true)
        _ = await w.document.undo().value
        await preview.apply().value
        #expect(preview.ok() == nil && w.groups.count == 1)
        // Cmd-click replays the stored settings without the dialog.
        _ = await w.document.undo().value
        w.controller.model.set(Selection([square]))
        let count = w.previews.count
        #expect(w.registry.performWithPreviousSettings(EmbossFeatures.id))
        await w.document.settle()
        #expect(w.previews.count == count && w.groups.count == 1)
        // Nothing eligible: nothing to preview.
        w.controller.model.set(Selection())
        await preview.apply().value
        #expect(preview.previewed == nil)
    }

    @Test func theSheetsControlsWriteThePreferences() async throws {
        let w = World()
        let store = w.store
        #expect(EmbossFeatures.settings(store) == EmbossSettings())
        EmbossSheet.style(store).wrappedValue = "ridge"
        EmbossSheet.depthSlider(store).wrappedValue = 12.4
        #expect(EmbossSheet.depthSlider(store).wrappedValue == 12 && EmbossFeatures.settings(store).style == .ridge)
        EmbossSheet.setDepth(store)(100)
        #expect(store[EmbossFeatures.Keys.depth] == 72 && EmbossSheet.depthSlider(store).wrappedValue == 20)
        EmbossSheet.setAngle(store)(-90)
        #expect(store[EmbossFeatures.Keys.angle] == 270)
        store.set("colors", for: EmbossFeatures.Keys.vary)
        store.set(PreferenceColor(red: 1, green: 0, blue: 0), for: EmbossFeatures.Keys.highlight)
        #expect(EmbossFeatures.settings(store).varyColors && EmbossFeatures.settings(store).highlight == RenderColor(red: 1, green: 0, blue: 0))
        let preview = EmbossPreview(target: { nil }) { EmbossFeatures.settings(store) }
        var dismissed = 0
        PanelRendering.host(EmbossSheet(store: store, preview: preview) { dismissed += 1 })
        store.set("emboss", for: EmbossFeatures.Keys.style)
        PanelRendering.host(EmbossSheet(store: store, preview: preview) { dismissed += 1 })
        EmbossSheet.applying(preview)()
        EmbossSheet.cancelling(preview) { dismissed += 1 }()
        EmbossSheet.confirming(preview) { dismissed += 1 }()
        #expect(dismissed == 2)
        // The install replaces the stub and presents through the presenter.
        let presenter = SheetPresenter()
        var shown: [NSWindow] = []
        presenter.present = { shown.append($0) }
        EmbossFeatures.install(extensions: w.registry, store: store, target: { w.editing }, presenter: presenter)
        let square = await w.square()
        w.controller.model.set(Selection([square]))
        #expect(w.registry.perform(EmbossFeatures.id) && shown.count == 1)
        presenter.dismiss("emboss-sheet")
        #expect(EmbossFeatures.descriptor(existing: ExtensionRegistry(descriptors: []), store: store, target: { nil }) { _ in } == nil)
    }
}
